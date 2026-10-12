//
//  AppTextSizeRenderingTests.swift
//  nodeseekTests
//
//  Created by Codex on 2026/5/10.
//

import Testing
import UIKit
@testable import nodeseek

@Suite(.serialized)
struct AppTextSizeRenderingTests {
    @Test func detailHTMLRendererUsesAppTextSizeForBodyText() throws {
        let configuration = AppTypography.Configuration(followsSystem: false, pointOffset: 2, category: .large)

        let blocks = configuration.performAsCurrent { DTCoreTextHTMLContentRenderer().render(
            fragment: "<p>正文预览</p>",
            baseURL: try #require(URL(string: "https://www.nodeseek.com")),
            maxImageWidth: 320
        ) }

        let font = try #require(renderedFont(in: blocks, matching: "正文预览"))
        #expect(font.pointSize == 19)
    }

    private func renderedFont(in blocks: [RenderedContentBlock], matching text: String) -> UIFont? {
        for block in blocks {
            switch block {
            case .text(let attributed):
                let range = (attributed.string as NSString).range(of: text)
                guard range.location != NSNotFound else { continue }
                return attributed.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
            case .quote(let quoteBlock):
                if let font = renderedFont(in: quoteBlock.children, matching: text) {
                    return font
                }
            case .vote, .terminal, .tabs, .table, .codeBlock, .image, .iframeLink, .imagePlaceholder, .unsupported:
                continue
            }
        }
        return nil
    }
}
