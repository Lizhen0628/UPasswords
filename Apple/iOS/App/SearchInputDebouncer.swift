//
//  SearchInputDebouncer.swift
//  UPasswords
//
//  搜索框输入防抖:逐键只记录文本,停顿后一次性应用,避免逐键重过滤/重渲染。
//

import Foundation

/// 搜索输入防抖器:逐键记录文本,停顿 `interval` 后回调一次;输入清空或主动
/// 清除则立即回调。AppContext 用它分离「逐键 searchText(不广播)」与
/// 「防抖 searchQuery(驱动列表过滤)」,消除逐键整树重渲染的输入卡顿。
@MainActor
final class SearchInputDebouncer {

    /// 停顿该时长后才应用搜索。本地内存过滤本身毫秒级,200ms 足以合并快速键入;
    /// 过长(如 1s)会显得搜索迟钝。
    let interval: Duration

    /// 最近一次输入的文本(防抖到期后以此回调,保证应用的是最终值)。
    private(set) var text: String = ""

    /// 防抖到期回调,在主线程执行;参数为最终文本。
    private let apply: @MainActor (String) -> Void

    /// 进行中的防抖任务(每次键入重排一次)。
    private var task: Task<Void, Never>? = nil

    /// - Parameters:
    ///   - interval: 停顿防抖时长。
    ///   - apply: 防抖到期回调(主线程);空文本不走防抖、立即回调。
    init(interval: Duration, apply: @escaping @MainActor (String) -> Void) {
        self.interval = interval
        self.apply = apply
    }

    /// 逐键输入入口:记录文本并重排防抖;清空立即生效(删除到空时列表即时恢复)。
    func textChanged(_ text: String) {
        self.text = text
        task?.cancel()
        guard !text.isEmpty else {
            task = nil
            apply("")
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.interval)
            guard !Task.isCancelled else { return }
            self.apply(self.text)
        }
    }

    /// 主动清空(搜索框 ✕ 按钮):立即生效,并丢弃进行中的防抖。
    func clear() {
        task?.cancel()
        task = nil
        text = ""
        apply("")
    }
}
