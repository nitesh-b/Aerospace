// Insomnia pre-request script — reproduces N10Signer.swift (Aerospace project).
// Paste into a request/folder/collection's "Scripts > Pre-request Script" tab.
//
// Environment variables required (set in Insomnia environment):
//   n10ApiKeyHex     - hex-encoded HMAC key
//   n10AppVersion    - e.g. "5.2.0"
//   n10SystemName    - e.g. "iOS" or "tvOS"
//   n10SystemVersion - e.g. "17.4"
//
// GET  -> X-N10-SIG: "<unixSeconds>_<hmacSha256Hex>", message = "<unixSeconds>:<finalURL>"
// POST -> X-Network-Ten-Auth: base64("yyyyMMddHHmmss") in UTC, no HMAC
// Always -> User-Agent: "10play/<appVersion> <systemName> <systemVersion> UAP"
// tvOS only -> X-Network-Ten-App: same value as User-Agent

const CryptoJS = require('crypto-js');

const apiKeyHex = insomnia.environment.get('n10ApiKeyHex') || '';
const appVersion = insomnia.environment.get('n10AppVersion') || '';
const systemName = insomnia.environment.get('n10SystemName') || '';
const systemVersion = insomnia.environment.get('n10SystemVersion') || '';

const method = insomnia.request.method.toUpperCase();
const finalURL = insomnia.request.url.toString();
const timestamp = Math.floor(Date.now() / 1000);

const userAgent = `10play/${appVersion} ${systemName} ${systemVersion} UAP`;

insomnia.request.removeHeader('User-Agent');
insomnia.request.addHeader({ key: 'User-Agent', value: userAgent });

if (systemName.toLowerCase() === 'tvos') {
    insomnia.request.removeHeader('X-Network-Ten-App');
    insomnia.request.addHeader({ key: 'X-Network-Ten-App', value: userAgent });
}

if (method === 'GET') {
    const message = `${timestamp}:${finalURL}`;
    const key = CryptoJS.enc.Hex.parse(apiKeyHex);
    const hmacHex = CryptoJS.HmacSHA256(message, key).toString(CryptoJS.enc.Hex);
    const sig = `${timestamp}_${hmacHex}`;

    insomnia.request.removeHeader('X-N10-SIG');
    insomnia.request.addHeader({ key: 'X-N10-SIG', value: sig });
} else if (method === 'POST') {
    const d = new Date(timestamp * 1000);
    const pad = (n) => String(n).padStart(2, '0');
    const raw = `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}` +
                `${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}`;
    const token = CryptoJS.enc.Utf8.parse(raw).toString(CryptoJS.enc.Base64);

    insomnia.request.removeHeader('X-Network-Ten-Auth');
    insomnia.request.addHeader({ key: 'X-Network-Ten-Auth', value: token });
}
