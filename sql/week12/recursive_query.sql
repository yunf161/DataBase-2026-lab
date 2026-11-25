/* 第十二周：层级递归查询。
   层级结构：沿用 dbo.Category 的 ParentID（父级编号）自关联，不新建层级表。
   演示数据（第一阶段 03_sample_data.sql）：食品 FOOD ─┬─ 饮料 DRINK
                                                       └─ 零食 SNACK
                                         日用品 DAILY、文具 STATIONERY 为另外的根节点。
   本脚本在一个事务里临时补上孙节点和另一条分支，查完后 ROLLBACK，不改变库里的数据：
       食品 FOOD → 饮料 DRINK → 碳酸饮料 W12_SODA（孙节点、叶子）
       文具 STATIONERY → 书写工具 W12_WRITE → 中性笔 W12_GEL（另一条分支）
   递归 CTE：起点是指定分类（层级 0）；递归部分找“父级是上一层某个分类”的子分类，层级 +1，路径接上子分类名称；
   没有更深的子分类时递归自然结束。tr_Category_PreventCycle 已阻止成环，这里仍用 IdPath 判重并设 MAXRECURSION 32 作保险。
   路径列在起点和递归部分都转换为 nvarchar(1000)，类型和长度一致。 */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]%'
    THROW 51700,N'第十至十二周对象只部署到独立 W7 应用数据库',1;
GO
/* 查出指定分类及其全部后代：编号、名称、父级、层级（指定分类为 0）、路径。编号不存在时返回空结果集。 */
CREATE OR ALTER PROCEDURE dbo.usp_CategoryDescendants @CategoryID bigint
AS
BEGIN
    SET NOCOUNT ON;
    WITH tree AS (
        SELECT c.CategoryID, c.CategoryCode, c.CategoryName, c.ParentID, 0 AS Level,
               CAST(c.CategoryName AS nvarchar(1000)) AS Path,
               CAST('/'+CONVERT(varchar(20),c.CategoryID)+'/' AS varchar(1000)) AS IdPath
        FROM dbo.Category AS c
        WHERE c.CategoryID=@CategoryID
        UNION ALL
        SELECT child.CategoryID, child.CategoryCode, child.CategoryName, child.ParentID, t.Level+1,
               CAST(t.Path+N' / '+child.CategoryName AS nvarchar(1000)),
               CAST(t.IdPath+CONVERT(varchar(20),child.CategoryID)+'/' AS varchar(1000))
        FROM tree AS t
        JOIN dbo.Category AS child ON child.ParentID=t.CategoryID
        WHERE CHARINDEX('/'+CONVERT(varchar(20),child.CategoryID)+'/',t.IdPath)=0
    )
    SELECT CategoryID AS category_id, CategoryCode AS category_code, CategoryName AS category_name,
           ParentID AS parent_id, Level AS level, Path AS path
    FROM tree
    ORDER BY IdPath
    OPTION (MAXRECURSION 32);
END;
GO
/* ---------- 样例数据与四类查询（结束时回滚） ---------- */
SET XACT_ABORT ON;
IF OBJECT_ID(N'tempdb..#Tree') IS NOT NULL DROP TABLE #Tree;
CREATE TABLE #Tree(category_id bigint, category_code varchar(20), category_name nvarchar(50),
                   parent_id bigint, level int, path nvarchar(1000));
/* 验证结果用表变量保留：样例数据回滚时，局部临时表的行也会被回滚。 */
DECLARE @TreeCheck TABLE(CaseName nvarchar(40), StartCode varchar(20), Expected nvarchar(300),
                         Actual nvarchar(300), Passed bit);
BEGIN TRY
    BEGIN TRAN;
    DECLARE @food bigint=(SELECT CategoryID FROM dbo.Category WHERE CategoryCode='FOOD'),
            @drink bigint=(SELECT CategoryID FROM dbo.Category WHERE CategoryCode='DRINK'),
            @stationery bigint=(SELECT CategoryID FROM dbo.Category WHERE CategoryCode='STATIONERY'),
            @soda bigint, @write bigint, @gel bigint, @missing bigint, @actual nvarchar(300);
    IF @food IS NULL OR @drink IS NULL OR @stationery IS NULL
        THROW 51760,N'缺少第一阶段演示分类 FOOD、DRINK、STATIONERY',1;
    INSERT dbo.Category(CategoryCode,CategoryName,ParentID) VALUES('W12_SODA',N'碳酸饮料',@drink);
    SET @soda=SCOPE_IDENTITY();
    INSERT dbo.Category(CategoryCode,CategoryName,ParentID) VALUES('W12_WRITE',N'书写工具',@stationery);
    SET @write=SCOPE_IDENTITY();
    INSERT dbo.Category(CategoryCode,CategoryName,ParentID) VALUES('W12_GEL',N'中性笔',@write);
    SET @gel=SCOPE_IDENTITY();
    SET @missing=(SELECT MAX(CategoryID) FROM dbo.Category)+1000;

    PRINT N'样例层级关系（编号、父级）：';
    SELECT CategoryID AS category_id, CategoryCode AS category_code, CategoryName AS category_name,
           ParentID AS parent_id
    FROM dbo.Category ORDER BY CategoryID;

    PRINT N'1. 根节点：食品 FOOD';
    DELETE #Tree; INSERT #Tree EXEC dbo.usp_CategoryDescendants @food;
    SELECT * FROM #Tree;
    SELECT @actual=STRING_AGG(CONCAT(category_code,':',level),',') WITHIN GROUP (ORDER BY path) FROM #Tree;
    INSERT @TreeCheck VALUES(N'根节点','FOOD',N'FOOD:0、DRINK:1、SNACK:1、W12_SODA:2，共 4 行，孙节点路径为“食品 / 饮料 / 碳酸饮料”',@actual,
        IIF((SELECT COUNT(*) FROM #Tree)=4
            AND EXISTS(SELECT 1 FROM #Tree WHERE category_code='FOOD' AND level=0 AND parent_id IS NULL)
            AND EXISTS(SELECT 1 FROM #Tree WHERE category_code='DRINK' AND level=1 AND parent_id=@food)
            AND EXISTS(SELECT 1 FROM #Tree WHERE category_code='SNACK' AND level=1 AND parent_id=@food)
            AND EXISTS(SELECT 1 FROM #Tree WHERE category_code='W12_SODA' AND level=2 AND parent_id=@drink
                       AND path=N'食品 / 饮料 / 碳酸饮料'),1,0));

    PRINT N'2. 中间节点：饮料 DRINK';
    DELETE #Tree; INSERT #Tree EXEC dbo.usp_CategoryDescendants @drink;
    SELECT * FROM #Tree;
    SELECT @actual=STRING_AGG(CONCAT(category_code,':',level),',') WITHIN GROUP (ORDER BY path) FROM #Tree;
    INSERT @TreeCheck VALUES(N'中间节点','DRINK',N'DRINK:0,W12_SODA:1 的 2 行，路径从饮料开始',@actual,
        IIF((SELECT COUNT(*) FROM #Tree)=2
            AND EXISTS(SELECT 1 FROM #Tree WHERE category_code='DRINK' AND level=0)
            AND EXISTS(SELECT 1 FROM #Tree WHERE category_code='W12_SODA' AND level=1 AND path=N'饮料 / 碳酸饮料'),1,0));

    PRINT N'3. 叶子节点：碳酸饮料 W12_SODA';
    DELETE #Tree; INSERT #Tree EXEC dbo.usp_CategoryDescendants @soda;
    SELECT * FROM #Tree;
    SELECT @actual=STRING_AGG(CONCAT(category_code,':',level),',') WITHIN GROUP (ORDER BY path) FROM #Tree;
    INSERT @TreeCheck VALUES(N'叶子节点','W12_SODA',N'只有自身 W12_SODA:0 一行',@actual,
        IIF((SELECT COUNT(*) FROM #Tree)=1 AND EXISTS(SELECT 1 FROM #Tree WHERE category_code='W12_SODA' AND level=0),1,0));

    PRINT N'4. 另一条分支：文具 STATIONERY';
    DELETE #Tree; INSERT #Tree EXEC dbo.usp_CategoryDescendants @stationery;
    SELECT * FROM #Tree;
    SELECT @actual=STRING_AGG(CONCAT(category_code,':',level),',') WITHIN GROUP (ORDER BY path) FROM #Tree;
    INSERT @TreeCheck VALUES(N'另一分支','STATIONERY',N'STATIONERY:0,W12_WRITE:1,W12_GEL:2，不含食品分支',@actual,
        IIF((SELECT COUNT(*) FROM #Tree)=3
            AND EXISTS(SELECT 1 FROM #Tree WHERE category_code='W12_GEL' AND level=2 AND path=N'文具 / 书写工具 / 中性笔')
            AND NOT EXISTS(SELECT 1 FROM #Tree WHERE category_code IN ('FOOD','DRINK','W12_SODA')),1,0));

    PRINT N'5. 不存在的编号';
    DELETE #Tree; INSERT #Tree EXEC dbo.usp_CategoryDescendants @missing;
    SELECT * FROM #Tree;
    INSERT @TreeCheck VALUES(N'不存在的编号',CONVERT(varchar(20),@missing),N'空结果，0 行',
        CONCAT((SELECT COUNT(*) FROM #Tree),N' 行'),IIF((SELECT COUNT(*) FROM #Tree)=0,1,0));

    ROLLBACK;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
SELECT CaseName AS [查询], StartCode AS [起点], Expected AS [预期], Actual AS [实际（编号:层级）],
       IIF(Passed=1,N'通过',N'未通过') AS [结论]
FROM @TreeCheck;
SELECT N'递归查询' AS [项目], COUNT(*) AS [检查项], SUM(CONVERT(int,Passed)) AS [通过],
       COUNT(*)-SUM(CONVERT(int,Passed)) AS [失败]
FROM @TreeCheck;
IF EXISTS (SELECT 1 FROM dbo.Category WHERE CategoryCode LIKE 'W12[_]%')
    THROW 51761,N'样例分类没有回滚',1;
DROP TABLE #Tree;
GO
