declare module "*?raw" {
  const content: string;
  export default content;
}

// 测试环境绑定(cloudflare:test 的 env 类型经全局接口合并注入)
declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
  }
}
