import assert from "node:assert/strict";
import { test } from "node:test";
import { itemMatchesPage, parseSiteAssociation, siteAssociationMatches } from "../dist/index.js";

test("domain matching includes subdomains but not lookalike suffixes", () => {
    const association = { url: "https://example.com/login", mode: "domain" };
    assert.equal(siteAssociationMatches("https://login.example.com/anything", association), true);
    assert.equal(siteAssociationMatches("https://example.com.evil.test/", association), false);
    assert.equal(siteAssociationMatches("file://example.com/", association), false);
});

test("wildcard matching matches explicit URL patterns only", () => {
    const association = { url: "https://*.example.com/*", mode: "wildcard" };
    assert.equal(siteAssociationMatches("https://login.example.com/sign-in", association), true);
    assert.equal(siteAssociationMatches("http://login.example.com/sign-in", association), false);
    assert.equal(siteAssociationMatches("https://example.com/sign-in", association), false);
    assert.equal(siteAssociationMatches("https://login.example.com.evil.test/sign-in", association), false);
});

test("exact URL matching normalizes equivalent HTTP URLs and includes path", () => {
    const association = { url: "https://example.com/login", mode: "exactURL" };
    assert.equal(siteAssociationMatches("https://EXAMPLE.com/login", association), true);
    assert.equal(siteAssociationMatches("https://example.com/other", association), false);
    assert.equal(siteAssociationMatches("https://example.com/login?next=1", association), false);
});

test("legacy single website uses domain mode and invalid associations fail closed", () => {
    assert.equal(itemMatchesPage("https://a.example.com/login", { host: "example.com" }), true);
    assert.equal(itemMatchesPage("https://example.org/", { host: "example.com", sites: [] }), false);
    assert.equal(parseSiteAssociation({ url: "javascript:alert(1)", mode: "domain" }), null);
    assert.equal(parseSiteAssociation({ url: "https://example.com/*", mode: "exactURL" }), null);
});
