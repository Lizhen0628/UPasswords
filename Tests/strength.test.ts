import { describe, expect, it } from "vitest";
import { bruteEntropy, evaluateStrength, scorePassword } from "../src/lib/strength";

describe("PasswordStrength", () => {
  it("scores common passwords as 0", () => {
    for (const pw of ["123456", "password", "qwerty123"]) {
      expect(evaluateStrength(pw).score).toBe(0);
    }
  });

  it("scores long random strings as 4", () => {
    expect(scorePassword("7hZ!qL2#wR9$uX4&").score).toBe(4);
  });

  it("keyboard sequences score lower than random", () => {
    const seq = evaluateStrength("qwertyuiop");
    const rand = evaluateStrength("9xQ2m#Lp7z");
    expect(seq.entropy).toBeLessThan(rand.entropy);
  });

  it("bruteEntropy grows with length and charset", () => {
    expect(bruteEntropy("aaaaaaaa")).toBeLessThan(bruteEntropy("aA1!aA1!"));
    expect(bruteEntropy("")).toBe(0);
  });

  it("repeats are weak", () => {
    expect(evaluateStrength("aaaaaaaaaa").score).toBeLessThanOrEqual(2);
  });
});
