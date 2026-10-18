// mysql2 类型垫片:worker 侧只用到池/连接/查询的最小面,避免为类型引入
// @types/node(workers-types 与 node 全局类型冲突)。测试运行时用真实包。
declare module "mysql2/promise" {
  export interface ResultSetHeader {
    affectedRows: number;
    insertId: number;
  }
  export interface PoolConnection {
    query(sql: string, params?: unknown[]): Promise<[unknown, unknown]>;
    beginTransaction(): Promise<void>;
    commit(): Promise<void>;
    rollback(): Promise<void>;
    release(): void;
  }
  export interface Pool {
    query(sql: string, params?: unknown[]): Promise<[unknown, unknown]>;
    getConnection(): Promise<PoolConnection>;
    end(): Promise<void>;
  }
  export function createPool(options: Record<string, unknown>): Pool;
}
