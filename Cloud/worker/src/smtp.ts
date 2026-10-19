// SMTP 客户端:cloudflare:sockets 直连 smtp.163.com:465(SSL),仅发验证码邮件。
// 授权码只经 Worker secret 注入;错误信息只含状态码,绝不含账号/命令内容。
// cloudflare:sockets 懒加载:Node 测试环境(SMTP_MOCK)不会解析到该 workerd 模块。

import { bytesToB64, utf8, type Env } from "./util";

const EHLO_NAME = "api.upasswords.com";
const SMTP_TIMEOUT_MS = 15_000;
const REPLY_MAX_BYTES = 16384;

function wrap76(s: string): string {
  const lines: string[] = [];
  for (let i = 0; i < s.length; i += 76) lines.push(s.slice(i, i + 76));
  return lines.join("\r\n");
}

const ALT_BOUNDARY = "UPW-ALT-7F3A9C1D";

/// 构造 multipart/alternative MIME(纯文本 + HTML,纯函数,单测覆盖):
/// 不支持 HTML 的客户端回落纯文本,现代客户端渲染样式版。
export function buildMail(opts: {
  from: string;
  replyTo: string;
  to: string;
  subject: string;
  body: string;
  html: string;
}): string {
  return [
    `From: ${opts.from}`,
    `Reply-To: ${opts.replyTo}`,
    `To: ${opts.to}`,
    `Subject: =?UTF-8?B?${bytesToB64(utf8(opts.subject))}?=`,
    `Date: ${new Date().toUTCString()}`,
    "MIME-Version: 1.0",
    `Content-Type: multipart/alternative; boundary="${ALT_BOUNDARY}"`,
    "",
    `--${ALT_BOUNDARY}`,
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    wrap76(bytesToB64(utf8(opts.body))),
    `--${ALT_BOUNDARY}`,
    "Content-Type: text/html; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    wrap76(bytesToB64(utf8(opts.html))),
    `--${ALT_BOUNDARY}--`,
    "",
  ].join("\r\n");
}

/// 验证码 HTML 版:仅内联样式(邮件客户端不加载 <style>/外部资源),
/// 验证码居中加大加粗置色块中;中英双语与纯文本版保持一致。
/// 纯函数,单测覆盖。
export function verificationMailHtml(code: string, sensitive: boolean, lang: "zh" | "en" = "en"): string {
  const zh = lang === "zh";
  const titleMain = sensitive
    ? (zh ? "您的安全操作验证码" : "Your security code")
    : (zh ? "您的登录验证码" : "Your sign-in code");
  const footer = zh
    ? "若非本人操作，请忽略本邮件，您的数据安全不受影响。<br>验证码 10 分钟内有效。"
    : "If you did not request it, please ignore this email.<br>The code expires in 10 minutes.";
  return [
    '<!doctype html><html><body style="margin:0;padding:24px 12px;background:#f4f5f7;',
    "font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,'PingFang SC','Microsoft YaHei',sans-serif;\">",
    '<div style="max-width:420px;margin:0 auto;background:#ffffff;border-radius:14px;',
    'padding:32px 28px;text-align:center;">',
    '<div style="font-size:20px;font-weight:700;color:#1d1d1f;letter-spacing:.5px;">UPasswords</div>',
    `<div style="margin-top:16px;font-size:15px;color:#333333;">${titleMain}</div>`,
    '<div style="margin:18px auto 10px;padding:14px 10px 14px 20px;display:table;',
    'background:#eef4ff;border:1px solid #c9dcff;border-radius:10px;',
    'font-size:36px;font-weight:800;letter-spacing:10px;color:#0a5bd3;',
    'text-align:center;">',
    code,
    "</div>",
    `<div style="font-size:13px;color:#666666;">${zh ? "验证码 10 分钟内有效，请勿泄露给任何人。" : "This code expires in 10 minutes. Do not share it with anyone."}</div>`,
    '<div style="margin-top:22px;font-size:12px;color:#999999;line-height:1.7;">',
    footer,
    "</div>",
    "</div></body></html>",
  ].join("");
}

export async function sendVerificationMail(
  env: Env,
  to: string,
  code: string,
  purpose: string,
  lang: "zh" | "en" = "en",
): Promise<void> {
  if (env.SMTP_MOCK === "1") {
    console.log(JSON.stringify({ t: Date.now(), action: "smtp_mock", purpose, lang }));
    return;
  }
  const { subject, body } = verificationMailText(code, purpose === "sensitive", lang);
  const html = verificationMailHtml(code, purpose === "sensitive", lang);
  const mail = buildMail({ from: env.SMTP_FROM, replyTo: env.SMTP_REPLY_TO, to, subject, body, html });
  await smtpDeliver(env, to, mail);
}

/// 纯文本版(主题 + 正文):默认英文,zh 为中文单语。
/// 纯函数,单测覆盖。
export function verificationMailText(
  code: string,
  sensitive: boolean,
  lang: "zh" | "en",
): { subject: string; body: string } {
  if (lang === "zh") {
    return {
      subject: sensitive ? "UPasswords 安全操作验证码" : "UPasswords 登录验证码",
      body: [
        `您的 UPasswords 验证码:${code}`,
        "验证码 10 分钟内有效。",
        "若非本人操作,请忽略本邮件,您的数据安全不受影响。",
      ].join("\n"),
    };
  }
  return {
    subject: sensitive ? "UPasswords security code" : "UPasswords sign-in code",
    body: [
      `Your UPasswords verification code: ${code}`,
      "It expires in 10 minutes.",
      "If you did not request it, please ignore this email.",
    ].join("\n"),
  };
}

async function smtpDeliver(env: Env, to: string, mail: string): Promise<void> {
  const { connect } = await import("cloudflare:sockets");
  const socket = connect(
    { hostname: env.SMTP_HOST, port: Number(env.SMTP_PORT) || 465 },
    { secureTransport: "on", allowHalfOpen: false },
  );
  const reader = socket.readable.getReader();
  const writer = socket.writable.getWriter();
  const decoder = new TextDecoder();
  let buffer = "";

  // 读取一条 SMTP 回复(处理 250- 多行续行),匹配期号不符即抛错
  async function expect(code: number): Promise<void> {
    const deadline = Date.now() + SMTP_TIMEOUT_MS;
    for (;;) {
      const idx = buffer.indexOf("\r\n");
      if (idx < 0) {
        if (Date.now() > deadline) throw new Error("smtp read timeout");
        const { done, value } = await reader.read();
        if (done) throw new Error("smtp connection closed");
        buffer += decoder.decode(value, { stream: true });
        if (buffer.length > REPLY_MAX_BYTES) throw new Error("smtp reply too large");
        continue;
      }
      const line = buffer.slice(0, idx);
      buffer = buffer.slice(idx + 2);
      const match = /^(\d{3}) /.exec(line);
      if (match) {
        if (Number(match[1]) !== code) throw new Error(`smtp expected ${code} got ${match[1]}`);
        return;
      }
      // "NNN-" 续行:消费后继续找最终行
    }
  }

  async function send(line: string): Promise<void> {
    await writer.write(utf8(line + "\r\n"));
  }

  try {
    await expect(220);
    await send(`EHLO ${EHLO_NAME}`);
    await expect(250);
    await send("AUTH LOGIN");
    await expect(334);
    await send(bytesToB64(utf8(env.SMTP_USER)));
    await expect(334);
    await send(bytesToB64(utf8(env.SMTP_PASSWORD)));
    await expect(235);
    await send(`MAIL FROM:<${env.SMTP_FROM}>`);
    await expect(250);
    await send(`RCPT TO:<${to}>`);
    await expect(250);
    await send("DATA");
    await expect(354);
    // 点填充:正文行首 "." 加倍,结束以单独 "." 行
    const stuffed = mail.replace(/(^|\r\n)\./g, "$1..");
    await writer.write(utf8(stuffed + "\r\n.\r\n"));
    await expect(250);
    await send("QUIT");
    await expect(221);
  } finally {
    try {
      await writer.close();
    } catch {
      // 对端已关闭时忽略
    }
  }
}
