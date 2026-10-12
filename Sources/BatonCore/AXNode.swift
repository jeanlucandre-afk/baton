import Foundation
@preconcurrency import ApplicationServices

/// A copy of part of a window's accessibility tree. Sidebars are read from this copy, not from live
/// elements, so the same parser runs on a live window, a saved test fixture or a repair attempt.
public struct AXNode: Codable, @unchecked Sendable {
    public var role: String
    public var sub: String?
    public var title: String?
    public var desc: String?
    public var value: String?
    /// Web apps' DOM classes, joined with "." (e.g. "sand-agents-section__header.flex").
    public var classes: String?
    public var kids: [AXNode]
    /// The live element, for pressing a row. Not saved in fixtures.
    public var element: AXUIElement?

    enum CodingKeys: String, CodingKey { case role, sub, title, desc, value, classes, kids }

    public init(role: String, sub: String? = nil, title: String? = nil, desc: String? = nil, value: String? = nil,
                classes: String? = nil, kids: [AXNode] = [], element: AXUIElement? = nil) {
        self.role = role; self.sub = sub; self.title = title; self.desc = desc; self.value = value
        self.classes = classes; self.kids = kids; self.element = element
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        sub = try c.decodeIfPresent(String.self, forKey: .sub)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        desc = try c.decodeIfPresent(String.self, forKey: .desc)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        classes = try c.decodeIfPresent(String.self, forKey: .classes)
        kids = try c.decodeIfPresent([AXNode].self, forKey: .kids) ?? []
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(sub, forKey: .sub)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(desc, forKey: .desc)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(classes, forKey: .classes)
        if !kids.isEmpty { try c.encode(kids, forKey: .kids) }
    }

    /// The row's visible name: its title, else its description.
    var label: String { [title, desc].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "" }

    public var count: Int { 1 + kids.reduce(0) { $0 + $1.count } }

    /// Copies a window's tree, bounded so a huge or frozen window can't stall the caller.
    public static func capture(_ root: AXUIElement, maxNodes: Int = 6000, maxMillis: Double = 250, prune: NodeMatch? = nil) -> AXNode? {
        var truncated = false
        return capture(root, maxNodes: maxNodes, maxMillis: maxMillis, prune: prune, truncated: &truncated)
    }

    /// The same, and `truncated` says whether it stopped at the node or time limit, so part of the
    /// window was never read (and a chat missing from the copy proves nothing). Elements matching `prune`
    /// are copied without what's inside them (see `Profile.prune`).
    public static func capture(_ root: AXUIElement, maxNodes: Int = 6000, maxMillis: Double = 250, prune: NodeMatch? = nil,
                               truncated: inout Bool) -> AXNode? {
        let start = Date()
        var budget = maxNodes
        var cut = false
        // A loop with its own stack, not recursion: a window nested thousands of levels deep (or one whose
        // tree loops back on itself) overflowed the thread's stack and crashed Baton. Deeper than
        // `maxDepth` is never a sidebar, so it's left out.
        var nodes: [AXNode] = []
        var kidIndices: [[Int]] = []
        var stack: [(el: AXUIElement, parent: Int, depth: Int)] = [(root, -1, 0)]
        while let (el, parent, depth) = stack.popLast() {
            guard budget > 0, Date().timeIntervalSince(start) * 1000 <= maxMillis else { cut = true; break }
            budget -= 1
            var v: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &v) == .success,
                  let a = v as? [Any], a.count == 7 else { continue }
            let n = AXNode(role: a[0] as? String ?? "", sub: a[5] as? String, title: nonEmpty(a[1]), desc: nonEmpty(a[2]),
                           value: (nonEmpty(a[3]) ?? (a[3] as? NSNumber)?.stringValue).map { String($0.prefix(200)) },
                           classes: (a[6] as? [String]).map { $0.joined(separator: ".") }, element: el)
            let i = nodes.count
            nodes.append(n)
            kidIndices.append([])
            if parent >= 0 { kidIndices[parent].append(i) }
            if prune?.matches(n) == true { continue }
            guard depth < maxDepth else { cut = true; continue }
            // Reversed, so children come off the stack (and into the copy) in their order.
            for k in (a[4] as? [AXUIElement] ?? []).reversed() {
                // A hung element must not hold the walk for the default 6 s.
                AXUIElementSetMessagingTimeout(k, AX.messagingTimeout)
                stack.append((k, i, depth + 1))
            }
        }
        guard !nodes.isEmpty else { truncated = cut; return nil }
        // Every child comes after its parent, so filling in from the end builds each subtree before its parent.
        for i in nodes.indices.reversed() where !kidIndices[i].isEmpty {
            nodes[i].kids = kidIndices[i].map { nodes[$0] }
        }
        truncated = cut
        return nodes[0]
    }

    /// Deeper than this, a copy stops going down: sidebars sit a few dozen levels in.
    public static let maxDepth = 150

    private static func nonEmpty(_ v: Any) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }

    nonisolated(unsafe) private static let attrs = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                                                     kAXChildrenAttribute, kAXSubroleAttribute, "AXDOMClassList"] as CFArray

    /// This tree as `capture` with `prune` would have copied it.
    public func pruned(_ m: NodeMatch?) -> AXNode {
        guard let m else { return self }
        var n = self
        n.kids = m.matches(self) ? [] : kids.map { $0.pruned(m) }
        return n
    }

    /// A copy safe to commit as a test fixture: no live elements, and long text (conversation content) dropped.
    public func trimmedForFixture(maxText: Int = 60) -> AXNode {
        func cut(_ s: String?) -> String? { s.flatMap { $0.count <= maxText ? $0 : nil } }
        return AXNode(role: role, sub: sub, title: cut(title), desc: cut(desc), value: cut(value),
                      classes: classes.map { String($0.prefix(80)) }, kids: kids.map { $0.trimmedForFixture(maxText: maxText) })
    }
}

/// Describes which element a profile means ("the AXList with subrole AXContentList"). Every field
/// that's set must match; fields left out match anything.
public struct NodeMatch: Codable, Sendable, Hashable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var desc: String?
    /// A substring of the element's DOM classes.
    public var classContains: String?

    public init(role: String? = nil, subrole: String? = nil, title: String? = nil, desc: String? = nil, classContains: String? = nil) {
        self.role = role; self.subrole = subrole; self.title = title; self.desc = desc; self.classContains = classContains
    }

    enum CodingKeys: String, CodingKey { case role, subrole, sub, title, desc, classContains }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        // Accept "sub" too: that's how the outline spells it, and models copy it.
        subrole = try c.decodeIfPresent(String.self, forKey: .subrole) ?? c.decodeIfPresent(String.self, forKey: .sub)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        desc = try c.decodeIfPresent(String.self, forKey: .desc)
        classContains = try c.decodeIfPresent(String.self, forKey: .classContains)
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(subrole, forKey: .subrole)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(desc, forKey: .desc)
        try c.encodeIfPresent(classContains, forKey: .classContains)
    }

    public func matches(_ n: AXNode) -> Bool {
        if let role, n.role != role { return false }
        if let subrole, n.sub != subrole { return false }
        if let title, n.title != title { return false }
        if let desc, n.desc != desc { return false }
        if let classContains, !(n.classes ?? "").contains(classContains) { return false }
        return role != nil || subrole != nil || title != nil || desc != nil || classContains != nil
    }

    /// Layout classes every web app puts on hundreds of elements; they don't single out a list.
    static let genericClasses: Set<String> = ["relative", "absolute", "fixed", "sticky", "static", "flex", "grid", "block", "inline",
                                              "inline-flex", "inline-block", "hidden", "contents", "group", "peer", "container",
                                              "truncate", "w-full", "h-full", "min-w-0", "min-h-0", "flex-1", "flex-col", "flex-row",
                                              "grow", "shrink-0", "overflow-hidden", "overflow-auto", "items-center", "isolate"]

    static func isGeneric(_ cls: String) -> Bool {
        genericClasses.contains(cls) || cls.contains(":") || cls.contains("[")
    }

    /// Matches nearly any container (a plain group, the window, a layout class), so every toolbar and
    /// message button would read as a chat.
    public var isTooLoose: Bool {
        guard subrole == nil, title == nil, desc == nil else { return false }
        if let classContains, !Self.isGeneric(classContains) { return false }
        return role == nil || ["AXGroup", "AXWindow", "AXWebArea", "AXScrollArea", "AXApplication", "AXSplitGroup"].contains(role!)
    }
}
