import Foundation
import JavaScriptCore

@objc protocol RSSArticleScriptExport: JSExport {
    var title: String { get set }
    var link: String { get set }
    var origin: String { get }
    var sort: String { get }
    var type: Int { get }
    var variable: String? { get set }
    func getVariable(_ key: String) -> String
    func putVariable(_ key: String, _ value: String)
}

/// Native对象只引用本次RuleData；不持有RSSStore或系统能力。
final class RSSArticleScriptObject: NSObject, RSSArticleScriptExport {
    var title = ""
    var link = ""
    let origin: String
    let sort: String
    let type: Int
    let data: RuleData

    init(source: RSSSource, sortName: String, data: RuleData, isListItem: Bool = false) {
        // Android先抽字段，再赋origin/sort/type；列表规则看到的是新文章的初值。
        self.origin = isListItem ? "" : source.sourceKey
        self.sort = isListItem ? "" : sortName
        self.type = isListItem ? 0 : (source.contentType?.rawValue ?? 0)
        self.data = data
    }

    var variable: String? {
        get { data.getVariableJSON() }
        set { data.variableMap = [:]; data.loadVariables(from: newValue) }
    }
    func getVariable(_ key: String) -> String { data.getVariable(key: key) }
    func putVariable(_ key: String, _ value: String) { data.putVariable(key: key, value: value) }
}
