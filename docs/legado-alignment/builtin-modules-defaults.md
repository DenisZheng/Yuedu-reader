# 内置模块改为用户主动启用（2026-11-15）

用户明确选择默认停用6个JSON插件，以及青空文库、Project Gutenberg两公共书库；此前选择的青空目录快照已撤回，不恢复Google/Firebase登录、付费或后台功能。

## 范围

- 六个JSON模块：Bangumi、AniList、openBD、Open Library、小説家になろう、热门趋势。保留随包文件与校验/保留ID规则，默认不执行其首页、搜索或资料补全。
- 两个原生公共书库：青空文库与Project Gutenberg，默认不进入首页/搜索提供者，不主动加载青空目录。
- AI配置、自建书源、用户导入模块、RSS和已保存书籍不变。
- 设置→模块→官方模块仍可打开配置；公共书库新增原生“启用”开关。用户主动启用后按原有实现使用。青空原版公共目录地址保留为手动启用路径，不声称该依赖永久消失，也不会默认访问它。

## 状态归属与升级

复用唯一`RuleModuleLibrary.disabled`，不建平行开关或缓存。新默认以`ruleModules.forkBuiltinDefaults.v1`一次应用：已有disabled集合与内置ID取并集，只改变内置启用状态；用户自建内容/隐藏设置/模块文件和其他偏好保持。以后手动启用的状态不会在重启时再被默认覆盖。

提供者注册、默认库列表、搜索与青空预加载都服从同一owner开关；Dev scheme启动不再使用`-no-official-modules`把文件彻底藏起，正常运行可手动恢复，测试隔离参数仍保留；仅隐藏卡片而继续请求不算停用。旧首页配置不删除，停用提供者后不请求对应行；手动重新启用可恢复原有配置。

## 撤回的快照

本会话新增的`aozora-catalog.json`、manifest、LICENSE和资源说明已经移除；`AozoraCatalogStore`、生成器与对应测试中的本会话来源切换改动已恢复。对照备份保留在`.git/review-withdraw-aozora.diff`及`.git/review-aozora-snapshot/`，不提交捕获或9.3MB快照。

## 验证

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
YUEDU_SCHEME=Reader-Fork-Dev bash scripts/xctest.sh -l .git/review-builtin-regression-green.log -- \
  -only-testing:'yuedu appTests/ForkBuiltinModulesDefaultsTests' \
  -only-testing:'yuedu appTests/SourceProviderRegistryTests' \
  -only-testing:'yuedu appTests/OfficialRuleModulesTests'
```

最终命令同上改用`.git/review-final-defaults.log`，实际结果：8 tests/3 suites通过，增加自建模块与隐藏配置不变断言。验证默认六插件/两公库关闭、官方文件仍在、手动开启Bangumi和青空后重启保持、默认提供者/列表为空、只开启青空时不带出Gutenberg。现有地域与连接回归使用显式启用fixture，不能把旧“默认全部启用”期望冒充新需求。

一次测试命令在机器离开期间超时，没有测试结论；进程已退出，未新建DerivedData、清理缓存或擦除模拟器。相同最小命令随后完成，未将超时当通过。

回滚仅撤回默认策略与相关闸门；不删除模块文件、自建数据或用户书籍。手动重新启用不需要回滚。
