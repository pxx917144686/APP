import Foundation

final class LRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private var storage: [Key: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private let capacity: Int
    private let queue = DispatchQueue(label: "com.app.lrucache", attributes: .concurrent)

    var count: Int {
        queue.sync { storage.count }
    }

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    subscript(key: Key) -> Value? {
        get {
            queue.sync(flags: .barrier) {
                getValue(for: key)
            }
        }
        set {
            queue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                if let value = newValue {
                    self.setValue(value, for: key)
                } else {
                    self.removeValue(for: key)
                }
            }
        }
    }

    func value(forKey key: Key) -> Value? {
        queue.sync(flags: .barrier) {
            getValue(for: key)
        }
    }

    func setValue(_ value: Value, forKey key: Key) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.setValue(value, for: key)
        }
    }

    func removeValue(forKey key: Key) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.removeValue(for: key)
        }
    }

    func removeAll() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.storage.removeAll()
            self.head = nil
            self.tail = nil
        }
    }

    private func getValue(for key: Key) -> Value? {
        guard let node = storage[key] else { return nil }
        moveToHead(node)
        return node.value
    }

    private func setValue(_ value: Value, for key: Key) {
        if let node = storage[key] {
            node.value = value
            moveToHead(node)
        } else {
            let node = Node(key: key, value: value)
            storage[key] = node
            addToHead(node)

            if storage.count > capacity, let tail = tail {
                removeNode(tail)
                storage.removeValue(forKey: tail.key)
            }
        }
    }

    private func removeValue(for key: Key) {
        guard let node = storage[key] else { return }
        removeNode(node)
        storage.removeValue(forKey: key)
    }

    private func addToHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil {
            tail = node
        }
    }

    private func removeNode(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
    }

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        removeNode(node)
        addToHead(node)
    }
}
