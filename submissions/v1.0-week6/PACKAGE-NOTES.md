# 第二阶段第5—6周独立提交说明

本包用于本组数据库实验第5—6周交付。先阅读根 README 与 docs/week6-normalization/README.md。
报告素材在 docs/week6-normalization/report-material.md；
逐项预期/实际和原始执行证据在 regression-results.md 与 results 目录。

两张 ER 图均附 draw.io 源文件、SVG 和 PNG；根 sql/tests 是当前修正实现。
submissions/v0.1-week4/sql 是原第一阶段 SQL 的逐字节副本，
供 Verify-Week6Migration.ps1 自动建立隔离迁移起点，不能用它覆盖迁移后的业务过程。
原有第一阶段完整包、旧报告和测试截图继续保留在主仓库，不重复混入本阶段的报告素材。
requirements 仅复制老师第五、六周任务说明。

v1.0-week6 表示第六周数据库交付，不表示第7—9周应用开发完成。
AI记录本次未修改，按组内安排另行核对；不将技术修正通过等同于AI材料已核对完成。

验证只在随机隔离库运行，结束自动清理；SSMS持久展示要从完整v0.1备份还原独立副本。
主入口和迁移入口均可从解压后的本包根目录运行，实例名称按实际SQL Server连接调整。
SHA256SUMS.json用于核对本包其余文件的内容。
