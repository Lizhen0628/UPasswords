//
//  SearchInputDebouncerTests.swift
//  UPasswords
//
//  搜索输入防抖:停顿后一次性应用、连续键入只应用最终值、清空立即生效。
//

import XCTest
@testable import UPasswords

@MainActor
final class SearchInputDebouncerTests: XCTestCase {

    /// 逐键输入不得立即应用,停顿超过 interval 后应用最终文本。
    func testDebounceAppliesAfterPause() async throws {
        var applied: [String] = []
        let debouncer = SearchInputDebouncer(interval: .milliseconds(100)) { applied.append($0) }
        debouncer.textChanged("git")
        XCTAssertTrue(applied.isEmpty, "防抖期间不得立即应用")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(applied, ["git"])
    }

    /// 快速连续键入只应用最后一个值(重排取消旧任务)。
    func testRapidInputCoalescesToLastValue() async throws {
        var applied: [String] = []
        let debouncer = SearchInputDebouncer(interval: .milliseconds(100)) { applied.append($0) }
        debouncer.textChanged("g")
        try await Task.sleep(for: .milliseconds(40))
        debouncer.textChanged("gi")
        try await Task.sleep(for: .milliseconds(40))
        debouncer.textChanged("git")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(applied, ["git"], "连续键入只应用最后一个值")
    }

    /// 输入清空(删除到空)立即生效,不走防抖。
    func testEmptyInputAppliesImmediately() async throws {
        var applied: [String] = []
        let debouncer = SearchInputDebouncer(interval: .milliseconds(100)) { applied.append($0) }
        debouncer.textChanged("git")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(applied, ["git"])
        debouncer.textChanged("")
        XCTAssertEqual(applied, ["git", ""], "清空立即生效,不等防抖")
    }

    /// 主动清空(✕ 按钮)立即应用空文本,且进行中的防抖不得再触发。
    func testClearAppliesImmediatelyAndCancelsPending() async throws {
        var applied: [String] = []
        let debouncer = SearchInputDebouncer(interval: .milliseconds(100)) { applied.append($0) }
        debouncer.textChanged("git")
        debouncer.clear()
        XCTAssertEqual(applied, [""], "clear 立即应用空文本")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(applied, [""], "clear 后进行中的防抖不得再触发")
    }
}
