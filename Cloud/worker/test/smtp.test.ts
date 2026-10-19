// 邮件构造单测:multipart 结构、纯文本回落、HTML 样式版内容。

import { describe, expect, it } from "vitest";
import { buildMail, verificationMailHtml, verificationMailText } from "../src/smtp";

function decodePart(mail: string, contentType: string): string {
  const marker = `Content-Type: ${contentType}`;
  const idx = mail.indexOf(marker);
  if (idx < 0) throw new Error(`part not found: ${contentType}`);
  const b64Start = mail.indexOf("\r\n\r\n", idx) + 4;
  const b64End = mail.indexOf("--UPW-ALT", b64Start);
  const b64 = mail.slice(b64Start, b64End).replace(/\r\n/g, "");
  return Buffer.from(b64, "base64").toString("utf8");
}

describe("verification mail", () => {
  const mail = buildMail({
    from: "noreply@upasswords.com",
    replyTo: "register@upasswords.com",
    to: "user@example.com",
    subject: "UPasswords 登录验证码",
    body: "plain body 123456",
    html: verificationMailHtml("123456", false, "zh"),
  });

  it("multipart/alternative with plain + html parts", () => {
    expect(mail).toContain('Content-Type: multipart/alternative; boundary="UPW-ALT-7F3A9C1D"');
    expect(mail).toContain("Content-Type: text/plain; charset=UTF-8");
    expect(mail).toContain("Content-Type: text/html; charset=UTF-8");
    expect(mail.trimEnd().endsWith("--UPW-ALT-7F3A9C1D--")).toBe(true);
    expect(decodePart(mail, "text/plain")).toContain("plain body 123456");
  });

  it("html: code centered/bold/large inside styled block", () => {
    const html = decodePart(mail, "text/html");
    expect(html).toContain("text-align:center");
    expect(html).toContain("font-size:36px");
    expect(html).toContain("font-weight:800");
    expect(html).toContain("123456");
    expect(html).toContain("10 分钟内有效");
    // 仅内联样式:客户端不加载 <style>/外部资源
    expect(html).not.toContain("<style");
    expect(html).not.toMatch(/src="http/);
  });

  it("html: sensitive purpose switches wording", () => {
    expect(verificationMailHtml("111111", true, "zh")).toContain("安全操作验证码");
    expect(verificationMailHtml("111111", false, "zh")).toContain("登录验证码");
  });

  it("defaults to English when no lang given", () => {
    expect(verificationMailHtml("222222", false)).toContain("Your sign-in code");
    expect(verificationMailText("222222", false, "en").subject).toBe("UPasswords sign-in code");
    expect(verificationMailText("222222", true, "en").subject).toBe("UPasswords security code");
  });

  it("zh templates are Chinese-only single language", () => {
    const zh = verificationMailText("333333", false, "zh");
    expect(zh.subject).toBe("UPasswords 登录验证码");
    expect(zh.body).not.toContain("verification code");
    const html = verificationMailHtml("333333", false, "zh");
    expect(html).not.toContain("Sign-in code");
  });
});
