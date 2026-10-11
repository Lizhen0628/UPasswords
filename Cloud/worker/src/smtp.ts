// SMTP 客户端:cloudflare:sockets 直连 smtp.163.com:465(SSL),仅发验证码邮件。
// 授权码只经 Worker secret 注入;错误信息只含状态码,绝不含账号/命令内容。

import { connect } from "cloudflare:sockets";
import { bytesToB64, utf8, type Env } from "./util";

const EHLO_NAME = "api.upasswords.com";
const SMTP_TIMEOUT_MS = 15_000;
const REPLY_MAX_BYTES = 16384;

function wrap76(s: string): string {
  const lines: string[] = [];
  for (let i = 0; i < s.length; i += 76) lines.push(s.slice(i, i + 76));
  return lines.join("\r\n");
}

/// 构造 UTF-8 纯文本 MIME(纯函数,单测覆盖)。
export function buildMail(opts: {
  from: string;
  replyTo: string;
  to: string;
  subject: string;
  body: string;
}): string {
  return [
    `From: ${opts.from}`,
    `Reply-To: ${opts.replyTo}`,
    `To: ${opts.to}`,
    `Subject: =?UTF-8?B?${bytesToB64(utf8(opts.subject))}?=`,
    `Date: ${new Date().toUTCString()}`,
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    wrap76(bytesToB64(utf8(opts.body))),
    "",
  ].join("\r\n");
}

export async function sendVerificationMail(
  env: Env,
  to: string,
  code: string,
  purpose: string,
): Promise<void> {
  if (env.SMTP_MOCK === "1") {
    console.log(JSON.stringify({ t: Date.now(), action: "smtp_mock", purpose }));
    return;
  }
  const subject = purpose === "sensitive" ? "UPasswords 安全操作验证码" : "UPasswords 登录验证码";
  const body = [
    `您的 UPasswords 验证码:${code}`,
    "验证码 10 分钟内有效。",
    "若非本人操作,请忽略本邮件,您的数据安全不受影响。",
    "",
    `Your UPasswords verification code: ${code}`,
    "It expires in 10 minutes.",
    "If you did not request it, please ignore this email.",
  ].join("\n");
  const mail = buildMail({ from: env.SMTP_FROM, replyTo: env.SMTP_REPLY_TO, to, subject, body });
  await smtpDeliver(env, to, mail);
}

async function smtpDeliver(env: Env, to: string, mail: string): Promise<void> {
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
