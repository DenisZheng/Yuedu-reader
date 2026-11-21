// 完全自建的离线验收输入，不请求公网，不登录，不读取文件或修改系统设置。
const config = {
    bookSourceUrl: "https://mainjs-demo.invalid/#offline-fixture",
    bookSourceName: "mainJs 离线验收",
    bookSourceGroup: "离线验收",
    lastUpdateTime: 1,
    exploreUrl: [{title:"固定书单",url:"offline-list"}]
};
function search(key,page) {
    return [{name:"主脚本测试书",author:"离线作者",bookUrl:"https://mainjs-demo.invalid/book",
        intro:"这本书完全来自主脚本，不访问源站。",variable:{keyword:String(key),page:String(page)}}];
}
function explore(url,page) { return search(url,page); }
function getBookInfo(book) {
    return {intro:"搜索词："+book.getVariable("keyword")+"。下方目录和正文都由主脚本返回。",
        tocUrl:"https://mainjs-demo.invalid/toc"};
}
function getChapters(book) {
    return [
        {title:"卷一",url:"卷一",isVolume:true},
        {title:"第一章 离线正文",url:"https://mainjs-demo.invalid/chapter1",variable:{token:"第一章变量"}},
        {title:"第二章 上下文",url:"https://mainjs-demo.invalid/chapter2",variable:{token:"第二章变量"}}
    ];
}
function getContent(chapter,book,nextChapterUrl) {
    return chapter.title+"\n\n这是 mainJs 主脚本返回的离线正文。\n\n书名："+book.name+
        "\n章节变量："+chapter.getVariable("token")+"\n目录总数："+book.totalChapterNum+
        "\n下一章："+(nextChapterUrl || "没有下一章")+
        "\n\n切换章节、退出后重新进入，应该仍能阅读，卷一只能作为分卷标题。";
}
