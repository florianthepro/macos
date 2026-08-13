using System.Globalization;
using System.Text;
using System.Xml;

namespace MacOsUsbSetup.Core.PropertyList;

/// <summary>
/// Minimal Apple XML property-list reader/writer used to emit OpenCore's
/// config.plist. The object graph uses plain CLR types:
/// <see cref="IDictionary{TKey,TValue}"/> of string to object for &lt;dict&gt;,
/// <see cref="IList{T}"/> of object for &lt;array&gt;, plus string, bool,
/// long, double, <see cref="byte"/>[] (&lt;data&gt;) and DateTime.
/// </summary>
public static class Plist
{
    private const string DocType =
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">";

    public static string Write(object? root)
    {
        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        sb.Append(DocType).Append('\n');
        sb.Append("<plist version=\"1.0\">\n");
        WriteValue(sb, root, 0);
        sb.Append("</plist>\n");
        return sb.ToString();
    }

    public static object Read(string xml)
    {
        var doc = new XmlDocument();
        doc.XmlResolver = null;
        doc.LoadXml(xml);
        var plist = doc.DocumentElement
            ?? throw new FormatException("Property-list ohne Wurzelelement.");
        foreach (XmlNode child in plist.ChildNodes)
            if (child is XmlElement element)
                return ReadValue(element);
        throw new FormatException("Property-list enthält keinen Wert.");
    }

    private static void WriteValue(StringBuilder sb, object? value, int depth)
    {
        var pad = new string('\t', depth);
        switch (value)
        {
            case null:
                sb.Append(pad).Append("<string></string>\n");
                break;
            case string s:
                sb.Append(pad).Append("<string>").Append(Escape(s)).Append("</string>\n");
                break;
            case bool b:
                sb.Append(pad).Append(b ? "<true/>\n" : "<false/>\n");
                break;
            case byte[] data:
                sb.Append(pad).Append("<data>").Append(Convert.ToBase64String(data)).Append("</data>\n");
                break;
            case DateTime dt:
                sb.Append(pad).Append("<date>")
                  .Append(dt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture))
                  .Append("</date>\n");
                break;
            case double or float:
                sb.Append(pad).Append("<real>")
                  .Append(Convert.ToDouble(value).ToString(CultureInfo.InvariantCulture))
                  .Append("</real>\n");
                break;
            case sbyte or byte or short or ushort or int or uint or long or ulong:
                sb.Append(pad).Append("<integer>")
                  .Append(Convert.ToInt64(value).ToString(CultureInfo.InvariantCulture))
                  .Append("</integer>\n");
                break;
            case IDictionary<string, object?> dict:
                WriteDict(sb, dict, depth, pad);
                break;
            case System.Collections.IEnumerable list:
                WriteArray(sb, list, depth, pad);
                break;
            default:
                throw new NotSupportedException($"Plist unterstützt den Typ {value.GetType()} nicht.");
        }
    }

    private static void WriteDict(StringBuilder sb, IDictionary<string, object?> dict, int depth, string pad)
    {
        if (dict.Count == 0) { sb.Append(pad).Append("<dict/>\n"); return; }
        sb.Append(pad).Append("<dict>\n");
        var keyPad = new string('\t', depth + 1);
        foreach (var pair in dict)
        {
            sb.Append(keyPad).Append("<key>").Append(Escape(pair.Key)).Append("</key>\n");
            WriteValue(sb, pair.Value, depth + 1);
        }
        sb.Append(pad).Append("</dict>\n");
    }

    private static void WriteArray(StringBuilder sb, System.Collections.IEnumerable list, int depth, string pad)
    {
        var items = list.Cast<object?>().ToList();
        if (items.Count == 0) { sb.Append(pad).Append("<array/>\n"); return; }
        sb.Append(pad).Append("<array>\n");
        foreach (var item in items)
            WriteValue(sb, item, depth + 1);
        sb.Append(pad).Append("</array>\n");
    }

    private static object ReadValue(XmlElement element)
    {
        switch (element.Name)
        {
            case "string": return element.InnerText;
            case "true": return true;
            case "false": return false;
            case "integer": return long.Parse(element.InnerText, CultureInfo.InvariantCulture);
            case "real": return double.Parse(element.InnerText, CultureInfo.InvariantCulture);
            case "data": return Convert.FromBase64String(element.InnerText.Trim());
            case "date": return DateTime.Parse(element.InnerText, CultureInfo.InvariantCulture);
            case "dict": return ReadDict(element);
            case "array": return ReadArray(element);
            default: throw new FormatException($"Unbekanntes Plist-Element <{element.Name}>.");
        }
    }

    private static Dictionary<string, object?> ReadDict(XmlElement element)
    {
        var dict = new Dictionary<string, object?>(StringComparer.Ordinal);
        string? key = null;
        foreach (XmlNode node in element.ChildNodes)
        {
            if (node is not XmlElement child) continue;
            if (child.Name == "key") { key = child.InnerText; continue; }
            if (key is null) throw new FormatException("Plist-Wert ohne vorangehenden <key>.");
            dict[key] = ReadValue(child);
            key = null;
        }
        return dict;
    }

    private static List<object?> ReadArray(XmlElement element)
    {
        var list = new List<object?>();
        foreach (XmlNode node in element.ChildNodes)
            if (node is XmlElement child)
                list.Add(ReadValue(child));
        return list;
    }

    private static string Escape(string value) =>
        value.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
}
