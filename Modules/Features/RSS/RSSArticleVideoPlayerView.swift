import SwiftUI

/// RSS文章播放器只接收已准备的共享请求；AVPlayer控制器将时间写回RSSStore唯一权威状态。
struct RSSArticleVideoPlayerView: View {
    let owner: RSSStore
    let articleID: String?
    let attachmentKey: String
    let stream: VideoStream
    let resources: RSSMediaResourceSession
    let title: String
    var refresh: VideoPlaybackController.RSSRefresh? = nil
    @EnvironmentObject private var bookStore: BookStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VideoPlayerView(content: .rss(owner, articleID: articleID, attachmentKey: attachmentKey,
                                     stream, title: title, resources: resources, refresh: refresh)) { dismiss() }
            .environmentObject(bookStore)
    }
}
