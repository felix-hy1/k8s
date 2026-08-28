-- ============================================================
-- 06-StatefulSet / 02-test-queries.sql
-- 查询练习:验证 MySQL 就绪 + 熟悉数据
-- 用法(WSL 内):
--   kubectl exec -i mysql-client -n mysql-ns -- \
--     mysql -h mysql-0.mysql -uroot -pRoot@123456 < 02-test-queries.sql
-- ============================================================

USE k8s_learning;

-- 1. 基础查询
SELECT '== 全部学生 ==' AS section;
SELECT * FROM students;

-- 2. 聚合
SELECT '== 各专业人数与平均分 ==' AS section;
SELECT major, COUNT(*) AS cnt, ROUND(AVG(score), 2) AS avg_score
FROM students
GROUP BY major
ORDER BY avg_score DESC;

-- 3. 连接(与 courses 做笛卡尔演示,实际业务应建外键)
SELECT '== 学生 x 课程 排课候选(前 6 行) ==' AS section;
SELECT s.name AS student, c.name AS course
FROM students s
CROSS JOIN courses c
LIMIT 6;

-- 4. 服务器状态
SELECT '== 连接与版本 ==' AS section;
SELECT CURRENT_USER(), VERSION();
SHOW DATABASES;
