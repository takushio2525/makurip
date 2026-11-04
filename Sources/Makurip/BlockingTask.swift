import Foundation

/// CLI（main.swift の上から順に動くところ）で、async の処理が終わるまで待つ。
/// 中の処理はメインのスレッドを使わない（待っている間、メインは塞がっている）
enum BlockingTask {
    private final class Box<Value>: @unchecked Sendable {
        var value: Value?
    }

    static func run<Value: Sendable>(_ body: @escaping @Sendable () async -> Value) -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<Value>()
        Task.detached {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        guard let value = box.value else { fatalError("待っていた処理が値を返さなかった") }
        return value
    }
}
