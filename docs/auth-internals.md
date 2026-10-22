# 认证内部细节

这份文档记录的是**实测结论**，不是猜的。每一条都标注了怎么验证的。

> ⚠️ 这些都依赖上游的内部实现。版本升级后可能变化，届时以实测为准。

---

## 1. 上游的两道门

请求到达 DSH 桌面端时，会被检查两件事：

| 检查 | 内容 | 失败表现 |
|---|---|---|
| 来源可信 | `Host` / `Origin` 是否为回环地址 | 直接拒绝，提示不可信来源 |
| 会话有效 | 是否带一个合法的浏览器会话 cookie | 跳到认证页面 |

两道门是**串联**的：来源不过，连会话都不会被看。

所以只在外面套一层反向代理是不够的——还得让请求"看起来来自本机"。

---

## 2. 来源改写

最小可行的改写：

```
Host    → 127.0.0.1:<上游端口>
Origin  → https://<你的域名>     （仅在原请求带 Origin 时）
Referer → 同上，只替换 scheme://host[:port] 部分
```

**几个细节**，都踩过：

- `Host` 要带上游端口。只写 `127.0.0.1` 不带端口，可能被判不匹配
- `Origin` 是**条件改写**。同源 GET 请求根本不带这个头，凭空补一个反而更可疑
- `Referer` 也必须改。漏掉它，某些 API 会以"来源非法"拒绝，而且报错信息不会指向 Referer

---

## 3. 会话 cookie

### 格式

```
cookie 值 = "v1." + b64url(JSON(payload)) + "." + b64url(HMAC-SHA256(key, b64url(JSON(payload))))

payload = {
  "version": 1,
  "authority": "127.0.0.1:3080",
  "issuedAt": <毫秒时间戳>,
  "expiresAt": <毫秒时间戳>
}
```

cookie 名不是固定的，由 authority 派生：

```
cookie 名 = "dsh-auth-" + b64url(sha256(authority))
```

**所以换端口或换主机名后，cookie 名会变**。排查"明明登录了却还是被踢"时，先确认名字对不对。

### 密钥从哪来

存在本机的凭据文件里（默认 `~/.dsh/.credentials.yaml`），结构大致是：

```yaml
records:
  client-connection/browser-session:
    kind: grant
    payload:
      version: 1
      secret: <base64url 字符串>
```

### ⚠️ 两个必须照做的点

**① 密钥要先 base64url 解码成 32 个原始字节**

```
secret 字段的值（字符串） ──base64url 解码──> 32 字节 ──> 作为 HMAC 的 key
```

**直接拿字符串当 key 算出来的签名永远不匹配。** 而且失败表现是"未认证"，
和"密钥读错了""cookie 名错了"完全一样，极难定位。

我们一开始就是在这里卡住的。验证方法：解出来长度不是 32 就说明路径错了。

**② TTL 上限正好 30 天**

二分定位的结论：

| TTL | 结果 |
|---|---|
| 30 天 | ✅ 接受 |
| 31 天 | ❌ 拒绝 |

所以配置里默认写 **29 天**，留一天余量。别想着"写长点省事"。

### 完整属性

```
dsh-auth-<hash>=v1.<payload>.<sig>
  ; Max-Age=<ttl 秒>
  ; Path=/
  ; Expires=<UTC 时间>
  ; HttpOnly
  ; SameSite=Strict
  ; Secure
```

**`Secure` 无条件加。** 手机永远是通过 Cloudflare 的 HTTPS 进来的；不加的话浏览器
会把这份 29 天的凭据也通过 `http://` 发出去，等于白送。

`HttpOnly` 只挡 JavaScript，不挡嗅探——所以真正起作用的是 `Secure`。

---

## 4. 怎么验证你实现的版本是对的

`src/proxy/auth/session-cookie.js` 导出了 `verify()`，可以拿真实代理签发的 cookie 来交叉验证：

```js
const m = require('./src/proxy/auth/session-cookie.js');

// 从运行中的代理登录一次，拿到它签的 cookie
const real = '<Set-Cookie 里 v1.xxx.yyy 那一段>';

console.log(m.verify(real));
// { ok: true, payload: { version: 1, authority: '127.0.0.1:3080', ... } }
```

**能验算通过 = 你的算法和上游完全一致。** 这比"看界面能不能打开"可靠得多，
因为界面可能因为缓存等原因显示正常，而底层其实没通。

反过来也应该成立：你的 `mint()` 产出的 `name` 必须和真实代理的 cookie 名相同。

---

## 5. 版本兼容

这些是内部实现，升级 DSH 后如果突然连不上，按这个顺序排查：

1. `auth.secretFile` 路径变了吗？（`~/.dsh/.credentials.yaml` 还在不在）
2. `auth.secretRecord` 的名字变了吗？（还是 `client-connection/browser-session`）
3. 解出来的密钥还是 32 字节吗？
4. cookie 名和上游期望的一致吗？（抓一次真实登录的 Set-Cookie 对比）
5. payload 字段有没有变化？（对比真实 cookie 解出来的 JSON）

前四条能覆盖绝大多数情况。真变了，`mint()` 里改字段即可。
