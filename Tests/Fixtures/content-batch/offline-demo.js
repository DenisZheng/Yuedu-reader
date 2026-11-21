// 自建离线验收源：只读写本源的批次计数，不联网、不登录、不读取文件。
const config = {
  bookSourceUrl: "https://batch-demo.invalid/#self-authored",
  bookSourceName: "批量正文离线验收",
  bookSourceGroup: "批量验收",
  maxBatchSize: 3
};
function search(key,page) {
  return [{name:"批量正文验收书",author:"自建样本",bookUrl:"https://batch-demo.invalid/book",
    variable:{search:key}}];
}
function getBookInfo(book) {
  return {intro:"请先在目录下载全部三章，再打开正文。批量内容显示批次编号，单章内容明确标单章路径。",
    tocUrl:"https://batch-demo.invalid/toc"};
}
function getChapters(book) {
  book.putVariable("flow","三章固定输入");
  return [0,1,2].map(function(i){return {title:"第"+(i+1)+"章",url:"https://batch-demo.invalid/chapter"+i,
    variable:{token:"变量"+(i+1)}};});
}
function getContent(chapter,book,nextChapterUrl) {
  return "单章路径\n"+chapter.title+"\n章节变量："+chapter.getVariable("token")+"\n书籍变量："+book.getVariable("flow");
}
function getContentBatch(chapters,book) {
  var count=(parseInt(source.getVariable()||"0",10)||0)+1;
  source.setVariable(String(count));
  chapters.forEach(function(chapter){
    java.cacheContent(chapter,"批量路径\n批次："+count+"\n"+chapter.title+
      "\n章节变量："+chapter.getVariable("token")+"\n书籍变量："+book.getVariable("flow"));
  });
}
