-- ============================================================
-- 06-StatefulSet / 01-init.sql
-- MySQL 初始化脚本:由 lab02-mysql-statefulset.yaml 的 ConfigMap
-- 挂载到 /docker-entrypoint-initdb.d/,仅首次初始化空数据目录时执行
-- ============================================================

CREATE DATABASE IF NOT EXISTS k8s_learning
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE k8s_learning;

-- 学生表(种子数据)
CREATE TABLE IF NOT EXISTS students (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    name       VARCHAR(50) NOT NULL,
    major      VARCHAR(50) NOT NULL,
    score      DECIMAL(5,2) DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students (name, major, score) VALUES
  ('张三', '计算机科学', 88.50),
  ('李四', '软件工程',   92.00),
  ('王五', '网络工程',   79.50);

-- 课程表(供 02-test-queries.sql 的 JOIN 练习)
CREATE TABLE IF NOT EXISTS courses (
    id      INT AUTO_INCREMENT PRIMARY KEY,
    name    VARCHAR(50) NOT NULL,
    teacher VARCHAR(50) NOT NULL,
    credits INT DEFAULT 2
);

INSERT INTO courses (name, teacher, credits) VALUES
  ('Kubernetes 基础', '王老师', 3),
  ('Go 语言程序设计', '李老师', 3),
  ('分布式系统',      '陈老师', 4);

-- 业务账号:应用连接请用它,不要用 root
CREATE USER IF NOT EXISTS 'dev'@'%' IDENTIFIED BY 'Dev@123456';
GRANT SELECT, INSERT, UPDATE, DELETE ON k8s_learning.* TO 'dev'@'%';
FLUSH PRIVILEGES;
