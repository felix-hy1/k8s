-- ============================================================
-- 19-综合实战 / init.sql
-- WordPress 项目 MySQL 初始化脚本
-- 说明:
--   1) wordpress 主库由镜像环境变量 MYSQL_DATABASE=wordpress 自动创建
--   2) 本脚本由 ConfigMap 挂载到 /docker-entrypoint-initdb.d/,
--      仅在 PVC 为空(首次部署)时执行一次
--   3) 想重新执行:删除 PVC 并重建 Deployment(数据会清空!)
-- ============================================================

-- 部署审计库(演示配置→SQL→数据库的完整链路)
CREATE DATABASE IF NOT EXISTS wp_stats
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE wp_stats;

CREATE TABLE IF NOT EXISTS deploy_log (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    action   VARCHAR(100) NOT NULL COMMENT '动作:deploy/rollback/scale',
    operator VARCHAR(50)  DEFAULT 'learner' COMMENT '操作者',
    created  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) COMMENT '部署审计表';

INSERT INTO deploy_log (action, operator) VALUES
  ('initial deploy via k8s', 'learner'),
  ('mysql 8.0 pvc 8Gi',      'learner');

-- 应用专用账号(生产替代 root 连库的最佳实践)
CREATE USER IF NOT EXISTS 'wp_app'@'%' IDENTIFIED BY 'WpApp@123456';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wp_app'@'%';
GRANT SELECT, INSERT, UPDATE ON wp_stats.* TO 'wp_app'@'%';
FLUSH PRIVILEGES;

-- 验证(进入 mysql 后执行):
-- USE wp_stats; SELECT * FROM deploy_log;
-- SHOW GRANTS FOR 'wp_app'@'%';
