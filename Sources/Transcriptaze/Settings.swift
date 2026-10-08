import Foundation

extension Typesetting {
    static func load() -> Typesetting {
        let d = UserDefaults.standard
        var t = Typesetting()
        if let f = d.string(forKey: "type.face").flatMap(Typeface.init) { t.typeface = f }
        if let v = d.object(forKey: "type.size") as? Double { t.size = v }
        if let v = d.object(forKey: "type.lineHeight") as? Double { t.lineHeight = v }
        if let v = d.object(forKey: "type.measure") as? Double { t.measure = v }
        if let v = d.object(forKey: "type.showNumbers") as? Bool { t.showNumbers = v }
        if let v = d.string(forKey: "type.pageStyle").flatMap(PageStyle.init) { t.pageStyle = v }
        return t
    }

    func save() {
        let d = UserDefaults.standard
        d.set(typeface.rawValue, forKey: "type.face")
        d.set(Double(size), forKey: "type.size")
        d.set(Double(lineHeight), forKey: "type.lineHeight")
        d.set(Double(measure), forKey: "type.measure")
        d.set(showNumbers, forKey: "type.showNumbers")
        d.set(pageStyle.rawValue, forKey: "type.pageStyle")
    }
}
