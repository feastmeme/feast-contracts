# Feast v1.6 tokenomics

> **Status:** the spec of unit v1.6 (task 428). Part 1 is the owner's technical
> plan of 2026-09-11, copied verbatim; Appendix A is the distribution rules it
> implements, copied verbatim. Decisions, the package split and the measured gas
> numbers are appended below them as the unit lands.
>
> **One edit, and only one:** personal names are replaced by role labels
> ("所有者" = the owner; "提名人A/提名人B" = the two partner nominators), because
> no committed file may carry a personal identity string
> (`tools/check-boundaries.py`, identity). No other byte of either document was
> changed. The originals stay where the owner keeps them.

---

## Part 1 — technical plan (verbatim)

# Feast v1.6 代币分发方案——技术实现分析(2026-09-11 17:0x;基于 feast-contracts master v1 + v1.1/platform-buttons 现状)

> 输入:分发与合作伙伴方案 v1.6(同目录 distribution-and-partners-v1.6-20260911.md)+ 9/11 下午 所有者 的裁决(无单址上限;创世伙伴 8 名各 0.1%,发射伙伴提名 4 个;KOL 用自己的链接、与伙伴怎么分自定;无伞式加成;无独占排期;权重 40/45/15→20/65/15)。
> 现状(已读源码):FeastFactory.launch 一笔交易建币+建池+登记 hook+创作者归属(FeastVesting,线性无 cliff,上限 20%);FeastToken 固定供应铸给工厂;FeastHook 每笔 1%(bStock 腿)按 平台 2000 / 创作者侧 8000(自烧默认 2000 上限 3000、推荐默认 1000 上限 3000、其余创作者)记桶,hookData 带推荐人,ReferralCredited 事件;FeastEpochRewards 记"每期(日)、每报价币、每付费人"的费(v1.5 的付费人账本);FeastConverter/FeastOracle 做 TWAP 换算;常量已预留 burnShare 30–70 与治理参数(VOTING_DELAY 1 天、PERIOD 7 天,v1.1 平台按钮分支)。

## 0. 一张表:要什么、有什么、缺什么
| 方案要求 | 现有件 | 要新建/改 | 估算 |
|---|---|---|---|
| 65% 公开发射,24h 统一价窗 | 工厂建池即发射、首块限购 | **FeastLaunchWindow** 合约 + hook 的 `openAt` 闸(窗关前只允许窗合约成交)+ 工厂给平台币的创世路径 | 合约 ~250 行 |
| 20% 团队 vesting(cliff+线性,不投票) | FeastVesting(线性无 cliff,绑创作者) | 团队用 OZ **VestingWallet+Cliff**(标准件);工厂创世路径把 20% 铸给它 | ~40 行接线 |
| 15% 一年 bootstrap,三赛道按费发,双上限,周结 | FeastEpochRewards(日期、只记付费人) | **FeastEmissions** 合约 + 账本扩到 推荐人/创作者 两维 + 周期(7 日) | 合约 ~450 行 |
| 推荐≠交易者 | hookData 推荐人 | hook 记账时若 referrer==payer 则视为无推荐(已部分有 ReferralCredited 语义,需断言) | ~10 行 |
| 唯一治理参数(价值比例 5–20%) | 常量与治理参数已预留 | OZ Governor + TimelockController(3 天),FEAST 改 ERC20Votes;治理对象=FeastEmissions.valueRatioBps | ~120 行接线 |
| 平台 20% 全部回购销毁 | v1.1/platform-buttons 分支(三层地板,审计第 5 轮四类未收) | 收口 v1.1 分支;去掉"一半进奖池"分叉(奖池职能由 Emissions 替代) | 已在做 |
| 创世伙伴 8×0.1% 按带来的费解锁 | 无 | **FeastGenesisGrants** 合约(8 地址创世钉死,按 Emissions 的推荐费账本解锁,6 个月截止,余量销毁) | ~150 行 |
| FEAST 自身参数(创作者=销毁地址、自烧 20、推荐 10) | 工厂 launch 参数 | 创世路径传参 | 0 |
| 推荐看板/排行榜/徽章、发射日历、发射窗 UI、领取台 | app 沙盒模式已真调合约 | 前端 5 页 + 读链索引(事件→周聚合) | 前端 1–2 周 |

## 1. 创世路径(工厂)
- 新增 `launchPlatformCoin(PlatformParams)`:仅部署者可调一次(一次性钥匙,调用后自毁权限,不引入常设 admin)。铸 100% 到工厂后按 65/20/15 分三路:65% 走既有建池逻辑(单边流动性,开盘价按 docs 的 tick 数学);20% `safeTransfer` 到团队 VestingWallet(cliff 12 或 6 个月,线性 36 或 30 个月,受益人=团队公开地址);15% 到 FeastEmissions。
- 池登记时带 `openAt = now + 24h`;hook 的 `beforeSwap` 在 `openAt` 前只放行 `msg.sender == launchWindow`。普通币 `openAt = 0`,行为不变。
- FEAST 的 hook 参数:creator=0x…dEaD,selfBurn 2000,referrer 1000。创作者侧其余 5000 也进销毁(creator=dEaD 时 claim 即烧)。

## 2. FeastLaunchWindow(24 小时统一价)
- `commit()` payable:窗内任何地址存 BNB(WBNB 包装),记 `committed[addr]`、`totalCommitted`;`withdraw()` 只在窗关前一小时之前允许,**最后一小时锁定**(所有者 9/11 19:1x 定:防『大额假承诺吓退别人、最后一刻撤走』,别人有一小时看清真实需求)。
- `settle()`:窗关后任何人可调一次。**v1.6.11 起它不是一笔 swap,而是一次真正的统一价拍卖**:
  - 固定档位 `tranche = 池内持仓 × WINDOW_TRANCHE_BPS / 10000`(5000,即一半);
  - 清算价 `p* = net / tranche`,其中 `net = totalCommitted - totalCommitted/100`(1% 手续费);
  - 池子**精确按 `p*` 开盘**,并挂上**一个**跨越整个可用区间的头寸,流动性 `L = √(tranche · net)`,持有未售出的另一半供应与全部 `net`;
  - 每人可领 `tranche × committed[addr] / totalCommitted`,补足权重的最后一位领走精确余数,一个单位都不剩。
- **为什么改**:旧版一笔 swap 沿曲线走完,人人付的是同一**均价**,但曲线终点是**边际价**,池子就被留在了比所有人成本高约 `sqrt(倍数)` 的位置。开盘前两个区块买入有 0.5% 每钱包上限,卖出**故意没有**,于是第一个卖的人把这块溢价从池子里取走,最后一个人吃掉。那是「统一均价 + 一场赛跑」,不是统一价。开盘价就等于成交价之后,窗内参与者在开盘第一个区块全部卖出,只损失手续费和自己的冲击,没有白送给谁的溢价。
- **为什么档位正好是一半**(不是谁挑的数,是两条要求逼出来的):(1) 开盘价 = 清算价,不给第一个卖的人溢价;(2) 结算后池子是**平衡的恒定乘积池**——两边在开盘价上等值,没有折点,也没有所有者可调的参数。设卖出比例为 `f`,则 `p* = net/(f·T)`,未售出的 `(1−f)·T` 在该价格上值 `net·(1−f)/f`;要等于报价一侧的 `net`,只能 `f = 1/2`。此时两边的单边流动性都等于 `√(f·T·net)`——所以 v1.6.12 干脆只挂**一个**全区间头寸,而不是两个恰好相等的。
  - 熟悉 pump.fun 的读者:它的 79.31% / 20.69% 也是平衡的,但那只是因为**曲线终价约为买家平均成本的 3.8 倍**(`0.2069 × 3.8 ≈ 0.7931`)。统一价没有这个倍数——人人付 `p*`,池子也开在 `p*`——所以唯一能平衡的比例就是一比一。那个倍数正是这次改动要消除的溢价;消除之后剩下的就是 `f = 1/2`。
- **v1.6.12:一个全区间头寸,开盘价就是 `p*`,不再对齐 tick。** 旧版挂两个区间,两者在清算 tick 上**相接**,而相接点必须是 tick spacing 的倍数,所以价格被迫对齐。一个全区间头寸没有相接点——只有端点要求是可用 tick,而两个极值本来就是——于是价格自由,开盘价精确等于 `p*`。这不是整理代码:两个区间合成一个之后,若价格仍被对齐,两边就不再等值,实测十枚 BNB 的池子会有 **1.2% 的报价没能进池**;同时第一个卖出者原本要为对齐多付最多一个 spacing(2.02%),现在也归零了。
- **为什么必须记下区间**:头寸的区间是它唯一的句柄。v1.6.11 挂了两个头寸而 hook 只记得一对 `(tickLower, tickUpper)`,于是 `collectLpFees` 向 venue 递交 `(0,0)` 并永久回滚——永久锁定的流动性一直在赚 LP 手续费,却永远收不出来。v1.6.11 审计轮的四个单元在两个家族里各自独立发现了它。
- 阳光:`committed`、`totalCommitted`、`tranche()` 与 `clearingPrice()` 公开可读,前端实时显示"当前隐含清算价"。
- 失败面:窗内零承诺→`settle()` 按创世价单边开池不买;**seed 失败**→`settled` 只在两个头寸都挂上之后才写,所以整笔回滚、窗口仍未结算、退款路径照常可达;宽限期内无人结算→全额退款(WBNB)。创世接线错误(本合约不是池的 opener)→永远无法结算,窗关即开放退款。
- **结算前池子根本不存在**:创世不再 initialize 也不 seed,因为它必须开在的那个价格要等窗关才知道。所以窗关之前任何人(包括 opener)都无法交易它,venue 在 hook 被问到之前就拒绝。
- **拍卖不写预言机**。只有 swap 写观察值,`initialize` 和 `modifyLiquidity` 不写,而拍卖里没有 swap。于是 FEAST 开盘后到第一笔真实成交之前,**有价格而没有历史**,`FeastPricer` 如实回答 `Unpriceable`——没有成交就没有价格。这对排放有后果:落在这段里的周按**写明的首周规则**(只用 token cap)结算,不去猜一个没人验证过的价格(所有者 2026-09-20 定,方案 A)。
- **1% 手续费的去向**:没有 swap 可以收它,由 `settle()` 直接以 WBNB 转给创世指定的 `platformSink`——和 `FeastHook.releasePlatformFees` 到达的是同一个地址,sink 会给它持有的任何资产定价并卖出,所以一次 transfer 就够。它不进任何账本、不发 `Trade`:它不是谁的交易。
- 不设每钱包上限(所有者 定);拆钱包无意义(按 BNB 比例)。

## 2c. 创世伙伴的空位:可以在 90 天内补一次(v1.6.12)

在 v1.6.12 之前,八个伙伴地址在创世时写死、没有 setter——所以**发射前必须先凑齐八个伙伴**,否则那些位置
只能烧掉。所有者 2026-09-20 18:5x 定:允许留空,事后补。

- **谁能补**:`TEAM_MULTISIG`——与守护者是**同一个地址**,而且是直接从守护者合约里读出来的
  (`guardian.guardian()`),不是第二个构造参数,因此两者不可能不一致。
- **什么时候**:创世后 **90 天**内,用的是守护者自己的那个截止时刻(`guardian.sunsetAt()`)——全系统一个数字,
  不是两个。
- **能补什么**:只有**空位**(`address(0)`)。创世时填好的、或者后来补上的位置,**一律不可更改**——
  多签不能替换、不能移除、不能改派任何人。补位**不移动任何价值**:那份 grant 本来就在合约里,
  并且仍然只按该伙伴自己带来的推荐费解锁。
- **六个月的解锁时钟从创世开始算,不重置**。第 85 天补进来的伙伴,拿到的是**剩下的那段**,不是完整的六个月。
- **补位之前的推荐费不算**。那个地址可能一直在以普通推荐人的身份带量;在补位那一刻**已经收盘的**排放周,
  对这个位置计为零(并且被永久标记为已计数,不会事后被捡回来)。补位当时**尚未收盘**的那一周整周计入——
  这是最多一周的宽松,如实写在这里,因为按小时切分一周的费用是周账本做不到的事,系统里也没有别的数字这么做。
- **没人来补的位置会烧掉**:窗口一关,`burnUnfilledSlot(slot)` 任何人可调,一次,把那份 grant 销毁。
  (这是一个**新入口**,因为原来的 `burnUnearned` 需要一个伙伴**地址**,而空位没有地址;没有它那份 grant
  会永远留在合约里,正是 I14 禁止的搁浅。)

## 2b. 守护者(guardian):一个只能刹车、永远碰不到钱的地址

v1.6.12 新增。设计与每一条裁定:`plans/audit/guardian-design.md`。

feast 没有 owner——这是整套设计里最强的一条,也是站点上写着的那句话。代价是:如果上线第三天发现缺陷,
**没有任何人能做任何事**。守护者买的只有**时间**,别的什么都没有。

- **地址**:`TEAM_MULTISIG`(与三天时间锁的提案人是同一个 Safe),构造参数写死,**没有 setter、不可转让**。
  换谁能拉闸是 Safe 内部的事(签名人、门槛、module),永远不是合约变更。
- **权力 A:`stopCreation()`**——一次性、单向、永不可撤。此后 `create` 永远回滚;创世、已有池子、领取、
  结算全部照常。**它不随 90 天失效**:第六个月才暴露的缺陷,同样值得有办法阻止**新增**敞口。
- **权力 B:`freeze(scope)`**——`ALL` 或单个 `PoolId`。冻结期间拒绝的是**资金流出**:hook 的
  `beforeSwap` 与各类领取、`collectLpFees`、平台 sink 的卖出、排放的结算与领取、各类归属领取,以及
  **每一处不可逆的销毁**(`burnExpired` / `burnRemainder` / `burnStray` / `burnUnearned`——销毁是最不可逆的
  一种价值移动,而它们都只有下界没有上界,推迟 72 小时不损失任何东西)。`ALL` 冻结还会在门口拒绝 `create`。
- **发射窗口不可冻结,这是决定而非疏漏。** 它的退款是**带时钟的**:冻结只会把它推过自己那一小时,
  把刹车变成没收。窗口里的钱是全系统里唯一仍属于承诺者自己的钱。
- **持币人自己的余额永不冻结。** ERC-20 / ERC-20Votes 的转账是拿自己的币和自己的交易对手做事,
  冻结它是对私产的权力,不是对协议的权力。
- **每一条边界都写在链上,不是承诺**:单次最多 `72 小时`(自动解除,`unfreeze` 只是礼貌);
  一生累计最多 `168 小时`;**创世后 90 天权力消失**,此后 `freeze` 永远回滚,且**任何人**都可以调用
  `expire()` 清掉残留的冻结——守护者生命的最后一步不应该还需要守护者。
- **它做不到的事**:移动任何余额、改任何比例或价格、阻止退款、延长自己的寿命、活过第 90 天。
- **成本**:每笔交易 **5,374 gas**(一次冷地址访问 + 一次冷 SLOAD),约为一笔交易的 2.3%。这是刹车存在的代价,
  如实记录而不是优化掉——把冻结状态内联进 hook 需要的字节数,hook 已经没有了(余量 642)。

它与既有的三天时间锁**并列而非串联**:时间锁管三个慢速排放杠杆(`setValueRatioBps`/`setRedirect`/`setPricer`),
守护者管分钟级的刹车。三天的刹车不是刹车,所以两者必须是不同的地址与不同的物理时间。

## 3. FeastEmissions(15%,52 周)
- **账本**:把 FeastEpochRewards 从"日、报价币、付费人"扩为"周、报价币、{payer, creator, referrer}"三维(或三张表),hook 每笔多写 2 条(creator 已知、referrer 来自 hookData 且 ≠ payer);`total[week][quote][track]`。
- **周结算** `settle(week)`(任何人可调,窗关后):
  1. 当周三赛道总费按报价币经 FeastConverter/TWAP 折成 BNB 价值 `feesBnb`;
  2. `valueCap = feesBnb × valueRatioBps / 10000 / twap(FEAST/BNB)`(FEAST 数量);
  3. `tokenCap = curve(week)`(**52 周线性递减**,所有者 9/11 19:1x 定:第 1 周最多、第 52 周最少,常量表,无台阶);
  4. `emitted = min(valueCap, tokenCap, remaining)`;按当周权重表(周 1–8:推荐 40/交易者 45/创作者 15;周 9+:20/65/15)分到三赛道;
  5. 每人 `claim(week)`:`emitted_track × mine[week][track] / total[week][track]`,多报价币按各自 BNB 价值加权(结算时把每个报价币的权重定在 `weightBnb[week][quote]`)。
- **截止**:第 52 周结算后未分配余量 `burn()`(任何人可调);已分配未领取给 12 周宽限,过期归销毁。
- **治理**:`valueRatioBps` 受 TimelockController 控制(3 天),Governor 以 FEAST(ERC20Votes)投票,提案门槛 1%、法定 4%(常量,可再议);团队 VestingWallet 不委托投票=不投票。
- gas:每笔 swap 多 2–3 次 SSTORE(BSC 可接受);结算为 O(报价币数)。

### 3b. 全链上 vs 链下 Merkle(所有者 9/11 19:1x 问;结论:全链上)
- **链下 Merkle 形**:hook 只发事件;索引器每周算分配、发 Merkle 根;用户带证明领取。省下每笔记账 gas、公式可随意改、合约只有 ~100 行分发器。代价:**必须有人发根**——要么一把可发根的钥匙(=admin key,方案第 6 节明令不做),要么乐观挑战期机制(比全链上账本更复杂、更难审);公式在链下,持币人无法在链上验证;索引器成为单点。与"所有分发按链上公式、无人手"的对外口径直接冲突。
- **全链上形(本方案)**:hook 每笔多写 payer/creator/referrer 三条周账与三条周总量;首次触碰的槽 20k gas,之后每次约 3k(EIP-2200 暖更新);最坏情况每笔约 +60–120k gas。BSC 按 0.1–1 gwei、BNB 约 900 美元算,每笔 +0.001–0.1 美元;一笔 100 美元交易付 1 美元手续费,记账成本 ≤ 1–9%,大额交易可忽略。v1 已在每笔 swap 写日期付费人账(FeastEpochRewards.record),所以这是"从 2 条扩到 6 条",不是从 0 到 6。结算与领取:报价币白名单 8–10 只,`claim(week)` 读 O(报价币×赛道) 个槽,约 60k gas;多周批量领取一个 `claimMany(weeks[])`。
- **省 gas 手法**:同一地址三赛道打包进一个槽(3×uint80 或 uint128 对);零推荐/零创作者份额时不写;周总量按报价币分槽,同周多笔交易暖槽;所有记账在 hook 的 `afterSwap` 一处完成。
- **退路**:事件照发;若 BSC 费率将来暴涨,可以不改 hook 只加一个 Merkle 分发器走链下——但那时要接受 admin key 或挑战期,是产品决定不是技术决定。

## 4. FeastGenesisGrants(8×0.1%)
- 创世钉死 8 个地址(部署前 所有者 拿到名单:发射伙伴提 4、提名人A/提名人B 提 4),`grant = 0.1% supply` 各;
- `unlocked(addr) = min(grant, grant × referredFeesBnb(addr, 0..now) / TARGET_BNB)`,`TARGET_BNB` 为常量(例如 20 万美元等值 BNB,创世定);6 个月截止,未解锁 `burn()`;
- 数据源=FeastEmissions 的推荐赛道账本(同一口径,不另记);
- 名额不可转让、不可改;地址错了只能作废(销毁)不能替换——对外正是"没有人手"的证据。

## 5. 平台 20% 全烧
- 沿用 v1.1 三层地板(按资产记账 / 本币烧腿内部撮合 / FEAST 挂单赎回),去掉 v1.5 的"一半进奖池"分叉;`burnShareBps` 及其治理退役(v1.6 唯一治理参数改为 Emissions 的价值比例)。

## 6. 前端与索引
- 发射窗页(倒计时、承诺、隐含均价、领取);奖励页(我的三赛道、本周预计、领取);推荐看板(链接、带来的成交/费、BNB 与 FEAST,可分享卡)+ 排行榜 + 创始推荐人徽章(周前 50);创世伙伴公开页(8 地址、解锁进度);团队 vesting 公开页;发射日历(任何创作者登记时间,数据不是推荐位);阳光页照旧。
- 读链:事件→周聚合的小索引器(可先用直接读合约存储,量小)。沙盒可整演全部(分叉上部署同一套)。

## 7. 审计范围与时间线
- 新增/改动约 1.0–1.3k 行 Solidity + 测试(含 OZ 标准件不计);审计增量约 1–1.5 周。
- **时间线 A(推荐)**:合约道 9/12–9/18 完成 v1.6(含 v1.1 收口),9/19 送审增量,报告约 10/3;**工厂 9/29 照开**(创作者币不依赖新件;平台费先累积),**FEAST 24h 发射窗 10/6 前后**,发射即开 Emissions 与 Genesis Grants;累积的平台费成为第一天回购销毁的预算(可对外讲)。
- **时间线 B**:工厂与 FEAST 同日 10/6 开。
- 供应切分、8 个地址、FEAST 自身参数、权重表、曲线、TARGET_BNB 在创世前定死。

## 8. 风险与边界
- 一笔 swap 走完 65% 单边曲线:均价由需求决定,承诺越多均价越高——这是设计不是缺陷,前端要把"当前隐含均价"实时给出。
- TWAP 在发射后头几小时不可靠:Emissions 首周结算若 TWAP 观测不足则按"tokenCap"单上限(写死规则,不猜价)。
- 账本 gas:每笔多写两条;若 BSC 费率上涨可把 referrer/creator 记账改为事件+链下索引,但那会让 Emissions 依赖索引器,不建议 v1。
- 治理:Governor 给了持币人改价值比例的权,团队锁仓不投票;若担心早期被大户操纵,把区间收窄(10–20%)比加人手更干净。
- 合规观感:团队 20% 锁仓+发射窗=常见的"公平发射+团队 vesting"形状;24h 窗内 BNB 进的是池不是我们的钱包,不是募资。

## 9. 已定与待定(2026-09-11 19:1x 更新)
- **已定(所有者 弹窗)**:时间线 A 且立单开合约道;曲线=52 周线性递减;发射窗最后一小时不可撤;全链上账本不做 Merkle(19:1x 问答,见 3b)。
- **待定**:团队 cliff(先研究 meme 台子惯例再第一性定,研究在跑);价值比例 15;TARGET_BNB;发射伙伴 1 或 2 个名额;Governor 门槛 1%/4%。合约道以这些为创世参数,部署前定死即可,不阻塞开发。


---

## Appendix A — distribution and partner rules (verbatim)

# Feast 平台币分发与合作伙伴整体方案(v1.6 草案,2026-09-11 16:0x;候 所有者 定稿)

> 由 9/11 下午与 所有者 的六轮第一性讨论收敛而成:统一沙盒预览、65/20/15 供应、24 小时统一价、一年 bootstrap、创世伙伴 8 名、开放推荐赛道、发射伙伴(经纪商节点)。定稿后并入方案正本第 10 节(v1.6)并改一页纸与 FAQ。

## 0. 目标函数与四条原则
目标只有一个:最大化平台成功概率(真交易者与真创作者的数量与留存)。代币是手段。四条原则:①激励是助燃剂不是氧气,预算一年,剩余销毁;②所有分发按链上公式,无人手分配、无豁免、无折扣;③多劳多得,不设单址上限(所有者 定),只防自推;④平台一分不留,平台手续费全部回购销毁 FEAST。

## 1. 供应与发射
| 桶 | 比例 | 规则 |
|---|---|---|
| 公开发射 | 65% | 24 小时统一价窗:窗内所有 BNB 汇总按一个清算价成交,**池子就开在那个价格上**,窗关池开;BNB 全部留在永久锁定的 FEAST/BNB 池;团队用公开地址同价买 |
| 团队 | 20% | 不可升级 vesting(仓内 FeastVesting),cliff 12 个月(团队现金压力大则 6 个月)+ 36 个月线性;锁仓期不投票;团队不拿任何手续费 |
| 一年 bootstrap | 15% | 52 周按"付过的费"发,见第 2 节;第 52 周剩余销毁 |

FEAST 作为工厂第一枚币的自身参数(创世锁定):创作者=销毁地址、自烧 20、推荐 10、其余进烧(合计九成烧、一成给带客的人)。

## 2. 一年 bootstrap 桶的发放规则
- **按费发**:每周结算,三条赛道——交易者按付出的手续费、创作者按赚到的手续费、推荐人按被推荐交易产生的手续费总额(不看创作者给推荐人设了多少比例)。
- **权重**(所有者 9/11 16:2x 定):前 8 周 推荐 40 / 交易者 45 / 创作者 15;第 9 周起 推荐 20 / 交易者 65 / 创作者 15。理由:创作者主报酬是 50% 分成,附赠不敏感;推荐人对附赠最敏感且冷启动最缺分发;交易者的返还(有效费率 0.85%)主要买的是持有人广度。
- **双上限**:每周发放的 FEAST 按 TWAP 计价不超过当周手续费的 15%(低于 20% 的回购,协议永远是净买家);另按 52 周递减曲线设当周代币数量上限;取小值。
- **无单址上限**,多劳多得;唯一的防刷规则=推荐地址不得等于交易地址。刷量净亏八成五,不必再防。
- **唯一可治理参数**:那个 15% 的价值比例,区间 5% 到 20%,FEAST 持有人投票加 3 天时间锁;团队锁仓币不投票。
- **不设伞式加成**(所有者 9/11 16:4x 否决:对外像二级返佣、合约多一套登记结算;拥有网络的人靠拥有链接与分账合约自然获利,规则只剩『谁带来的手续费,FEAST 就发给谁控制的地址』)。

## 3. 合作者与各自的钱(全部由合约兑现,没有一份要签的纸)
| 角色 | 人数 | 给什么 | 义务 | 不给 |
|---|---|---|---|---|
| **创世伙伴**(对外:Genesis Partners;若你偏好熟悉的桶名可叫 Genesis Advisors,但 meme 圈会读成内部配额,我建议 Partners) | 8 名(发射伙伴提名 4、提名人A 与提名人B 提 4) | 各 0.1% 供应(合计 0.8%,出自 15% 桶),按其链接带来的手续费在 6 个月内解锁,未解锁销毁;名单公开;沙盒先玩;上线周发射时间协调(推荐位与播报顺序仍由公开脚本按数据定) | 上线前公开站台、上线周覆盖、沙盒反馈 | 现金、折扣、保本、豁免 |
| **创始推荐人**(Founding Referrers,开放) | 不限 | 前 8 周任何人生成链接即可;按第 2 节规则领 FEAST;每周排行前 50 自动获"创始推荐人"徽章(只给地位) | 无 | 名额、申请、审批 |
| **发射伙伴**(Launch Partner,经纪商节点) | 1 到 2 家 | 推荐与创作者赛道的 FEAST 与 BNB 分成落在他控制的链接与分账合约上(量大);8 个创世伙伴名额提名 4 个(自己可占);沙盒现在开、职业作者 API 优先、产品直线反馈;发射**时间协调**(顺序与推荐位仍由公开脚本按数据定,No Build 不破)+ 开放的『即将发射』日历;公开署名(自愿,阳光名单照亮其捆绑与多钱包) | 首两周带 5 到 10 枚有社区的币按排期上,每枚配 KOL 覆盖;沙盒反馈 | 做市配资(无国库可配,锁定池本身就是永不撤的做市商)、借币、期权、豁免、独家 |
| **创作者**(含发射伙伴带来的作者) | 不限 | 每笔 1% 的 80%:自烧 x、推荐 y、自留其余(默认 20/10/50,上限各 30,创建即锁);创作者赛道 FEAST;作者与经纪商的分账用分账合约自行处理 | 无 | 预分配、预售(币在第一块全在池里) |
| **KOL** | 不限 | 推荐分成(创作者所设比例,BNB 永久)+ 推荐赛道 FEAST;可被提名为创世伙伴;用自己的链接或发射伙伴的链接由双方自定 | 无 | 打币、现金、保本 |

## 4. 产品清单(要新建的)
| 件 | 进 v1? | 大小 |
|---|---|---|
| 24 小时统一价发射窗合约 | 是(FEAST 创世依赖) | 中 |
| 52 周发放模块(三赛道+双上限) | 是(供应切分创世锁定) | 中,费账本与 TWAP 预言机现成 |
| 团队 vesting 部署 | 是 | 小(FeastVesting 现成) |
| 推荐人看板(我的链接带来的成交、BNB、FEAST,可分享卡片)+ 推荐人排行榜 + 徽章 | 是 | 几天 |
| 『即将发射』日历页(任何创作者可登记发射时间;数据不是推荐位) | 建议 v1 | 几天 |
| 发币/交易 API(职业作者) | 建议 v1.1 | 中 |
| 合约审计范围相应扩大 | 是 | 约加一周 |

## 5. 对外口径
一句话:"65% 在 24 小时统一价发射中进入永久锁定池;15% 由第一年用平台的人按付出的手续费赚得,发放永远低于回购,剩余销毁;20% 团队四年锁仓,不拿一分手续费;平台手续费全部回购销毁。"
名字表:Genesis Partners(创世伙伴,8 名)/ Founding Referrers(创始推荐人,开放徽章)/ Launch Partner(发射伙伴)。

## 6. 不做
预售或私募;KOL 私募轮或打币;保本;折扣或保底配额;反狙击豁免;做市配资、借币、期权;链下积分与空投;返还高于手续费的交易挖矿;独家;任何需要 admin key 的分配。

## 7. 进审计前必须定的数(所有者)
cliff 12 或 6 个月;价值上限 15%;权重 40/45/15 → 20/65/15(已定);创世伙伴 8 名与 0.1%/人;FEAST 自身推荐 10;徽章按周排行前 50。谈判分工:发射伙伴由 所有者 亲谈(纯信息第一次),创世伙伴名单 提名人A 与提名人B 各提 4。

---

## Part 2 — measured per-swap gas (package 1 vs `v1-internal`)

Re-measured 2026-09-12 with everything package 1 now carries — the weekly ledger,
the gate, the referral rule, the internal fill (Q15), the `Trade` event (Q24) and
the metadata digest (Q23) — on the pinned fork (block 120,721,477), real vault
and pool manager, by `test/FeastGasDelta.t.sol`. The same file runs on
`git archive 4d008d1` (the `v1-internal` tree after the rename, byte-identical
logic) with only its `_deploy` changed to v1's constructors and v1's
`CreateParams`. `isolate = true` meters each swap as its own transaction, so
storage and account access start cold, as on chain.

**Measured at `optimizer_runs = 20_000`.** That setting fell to `1_000` on
2026-09-19 (owner) so that v1.6.10's two hook fixes would fit under EIP-170;
`FeastHook` went 24,659 → 22,155 bytes and a plain trade went up about 0.9%
(225,757 → 227,694 on `FeastReferrerBinding`'s zero-referrer fixture). The
deltas this section reports are differences between two trees compiled the same
way, so they are unaffected; the absolute figures are ~1% low against the tree
that ships. `docs/plan.md` §1 carries the setting.

Sixteen trades per quote token — {buy, sell} × {exact-in, exact-out} ×
{unreferred, referred} × {first in its week, warm} — against a real tokenised
stock (AAPLB) and against WBNB. *First* is the first trade of the ledger week;
*warm* repeats it in the same week. In this run every exact-input sale is
**filled** by the internal fill (the harness's one-coin sales fit inside the
bucket's allowance), so those eight rows measure a filled sale; an exact-input
sale that is not filled costs what the other branches cost.

**Summary** (the delta is the same on every branch and both quotes, to within
1k gas):

| Case | Δ gas per swap | Δ % of the whole swap | at 0.1 gwei, BNB = \$900 |
|---|---:|---:|---:|
| warm, unreferred | +11.9k to +12.7k | +4.1% to +5.2% | ≈ \$0.0011 |
| warm, referred | +17.3k to +18.1k | +5.7% to +7.0% | ≈ \$0.0016 |
| first in its week, unreferred | +28.9k to +29.8k | +8.4% to +10.5% | ≈ \$0.0027 |
| first in its week, referred | +51.5k to +52.3k | +13.7% to +17.6% | ≈ \$0.0047 |
| **filled sale**, warm | +59.9k to +65.4k | +20.8% to +25.3% | ≈ \$0.0056 |
| **filled sale**, first in its week | +94.1k to +99.6k | +26.1% to +33.5% | ≈ \$0.0089 |
| `create()` (metadata digest stored and emitted, gate fields) | +27.3k on ≈ 1.58M | +1.7% | ≈ \$0.0025 |

Where it goes:

- **The ledger** accounts for ≈ 7.8k warm / ≈ 25k first-in-week unreferred
  (measured by call trace in the first run: v1's two-slot daily record cost
  13,021 gas warm, v1.6's three-track record one packed word per distinct
  address plus one totals word). Keeping each slot a raw packed word rather than
  a struct copied through memory saved 2.4k–3.1k of that.
- **The `Trade` event** (Q24): ≈ 4k — four topics and five data words, the price
  read from the `getSlot0` call the oracle write already makes.
- **The gate and the referral rule**: ≈ 450 gas together.
- **A filled sale** adds ≈ 48k on top: the oracle's average (asked with `try`),
  the hook burning its quote claims, taking the coin and burning it, and the
  bucket and allowance writes. That is the burn itself, done inside the sale
  that supplies the coin — it replaces a separate buy-back swap (a whole
  transaction, paid by whoever presses the button, that moves the price) rather
  than adding one.

Swaps in the platform coin's own pool cost a little more than an ordinary
coin's (FEAST is `ERC20Votes`, and every transfer looks up delegates). Measured
on the pinned fork through the whole recipe, a warm exact-input buy of 1 WBNB:
**265,304 gas in FEAST's pool against 258,922 in an ordinary coin's, +6,382
(+2.5%)**.

**All thirty-two trades, and `create`:**

| Quote | Trade | v1 (`4d008d1`) | v1.6 package 1 | Δ gas | Δ % | filled |
|---|---|---:|---:|---:|---:|:---:|
| AAPLB | buy-exact-in/unreferred/first | 342,338 | 371,262 | +28,924 | +8.4% |  |
| AAPLB | buy-exact-in/unreferred/warm | 291,210 | 303,111 | +11,901 | +4.1% |  |
| AAPLB | buy-exact-in/referred/first | 376,598 | 428,096 | +51,498 | +13.7% |  |
| AAPLB | buy-exact-in/referred/warm | 303,825 | 321,125 | +17,300 | +5.7% |  |
| AAPLB | buy-exact-out/unreferred/first | 328,165 | 357,910 | +29,745 | +9.1% |  |
| AAPLB | buy-exact-out/unreferred/warm | 289,588 | 302,235 | +12,647 | +4.4% |  |
| AAPLB | buy-exact-out/referred/first | 340,780 | 393,025 | +52,245 | +15.3% |  |
| AAPLB | buy-exact-out/referred/warm | 302,206 | 320,254 | +18,048 | +6.0% |  |
| AAPLB | sell-exact-in/unreferred/first | 360,700 | 454,803 | +94,103 | +26.1% | yes |
| AAPLB | sell-exact-in/unreferred/warm | 287,924 | 347,871 | +59,947 | +20.8% | yes |
| AAPLB | sell-exact-in/referred/first | 339,119 | 438,637 | +99,518 | +29.3% | yes |
| AAPLB | sell-exact-in/referred/warm | 300,545 | 365,909 | +65,364 | +21.7% | yes |
| AAPLB | sell-exact-out/unreferred/first | 327,641 | 356,704 | +29,063 | +8.9% |  |
| AAPLB | sell-exact-out/unreferred/warm | 289,061 | 301,026 | +11,965 | +4.1% |  |
| AAPLB | sell-exact-out/referred/first | 340,263 | 391,828 | +51,565 | +15.2% |  |
| AAPLB | sell-exact-out/referred/warm | 301,685 | 319,053 | +17,368 | +5.8% |  |
| WBNB | buy-exact-in/unreferred/first | 302,729 | 331,804 | +29,075 | +9.6% |  |
| WBNB | buy-exact-in/unreferred/warm | 247,051 | 259,028 | +11,977 | +4.8% |  |
| WBNB | buy-exact-in/referred/first | 332,451 | 384,028 | +51,577 | +15.5% |  |
| WBNB | buy-exact-in/referred/warm | 259,676 | 277,056 | +17,380 | +6.7% |  |
| WBNB | buy-exact-out/unreferred/first | 284,000 | 313,822 | +29,822 | +10.5% |  |
| WBNB | buy-exact-out/unreferred/warm | 245,423 | 258,146 | +12,723 | +5.2% |  |
| WBNB | buy-exact-out/referred/first | 296,625 | 348,950 | +52,325 | +17.6% |  |
| WBNB | buy-exact-out/referred/warm | 258,049 | 276,176 | +18,127 | +7.0% |  |
| WBNB | sell-exact-in/unreferred/first | 318,657 | 412,835 | +94,178 | +29.6% | yes |
| WBNB | sell-exact-in/unreferred/warm | 245,878 | 305,902 | +60,024 | +24.4% | yes |
| WBNB | sell-exact-in/referred/first | 297,084 | 396,682 | +99,598 | +33.5% | yes |
| WBNB | sell-exact-in/referred/warm | 258,508 | 323,951 | +65,443 | +25.3% | yes |
| WBNB | sell-exact-out/unreferred/first | 285,590 | 314,729 | +29,139 | +10.2% |  |
| WBNB | sell-exact-out/unreferred/warm | 247,008 | 259,049 | +12,041 | +4.9% |  |
| WBNB | sell-exact-out/referred/first | 298,220 | 349,864 | +51,644 | +17.3% |  |
| WBNB | sell-exact-out/referred/warm | 259,640 | 277,087 | +17,447 | +6.7% |  |

| `create` (AAPLB) | — | 1,581,261 | 1,608,546 | +27,285 | +1.7% | |
| `create` (WBNB) | — | 1,571,141 | 1,598,434 | +27,293 | +1.7% | |

---

## Part 3 — how the contracts implement it, and every decision taken

The spec above is the owner's; this part records how the contracts implement it
and each decision taken on the way, with who took it. Sources of record:
`plans/v16/plan.md` (§R, §R2, §R3) and `plans/v16/coordinator-answers.md`.

### One unit, deployed in two steps

The whole of v1.6 is built, sealed and audited as **one unit** (owner, Q28). It
still *deploys* in the order immutability forces:

| Step | When | Contracts |
|---|---|---|
| day one | with the factory | `FeastFeeLedger`, `FeastHook` (gate, referral rule, platform exit, internal fill, `Trade`), `FeastFactory` (one-shot `genesis`, metadata digest), `FeastPlatformTokenDeployer` / `FeastPlatformToken`, the v1 oracle, converter and vesting |
| at the opening | soon after the factory opens (Q25) | OpenZeppelin `TimelockController`, `FeastPricer`, `FeastEmissions`, `FeastGenesisGrants`, `FeastPlatformSink` |
| at the TGE | when the owner decides (Q25) | `FeastLaunchWindow`, `FeastTeamVesting`, then the one genesis call |

The day-one contracts carry **no later address** in their bytecode: the genesis
call — one key, once, self-disabling — names the launch window (as the platform
coin pool's opener), the three token recipients and the platform sink, and each
must report its own role and platform coin (`IFeastGenesisRecipient`). The
platform coin's own address is fixed from day one by `CREATE2`, so everything
after is built against it before it exists.

### How weeks settle before the platform coin exists (Q25)

Emission week 1 is the ledger week the factory opens in (Q8), and the platform
coin may be minted weeks later. A settled week's pots are **accounting**: every
pot is taken out of `remaining`, which starts at exactly the 14.2% genesis will
deliver, so the sum of everything ever settled can never exceed what arrives.
Until the platform coin's pool opens nobody can claim, nothing can expire and
nothing can burn; a pre-launch week settles under the first-week rule — the token
cap alone, at the full weekly cap, never a guessed price. When the window settles
and the pool opens, every settled pot is fully funded and claimable, and a week's
12-week expiry runs from the later of its settlement and that opening.

**After launch the value cap always binds** (internal round 4, H1). The
first-week rule is keyed on the launch state — the platform coin's pool not yet
open — never on whether a price happens to be available. Once the pool has
opened, a platform price the oracle will not vouch for (moved more than ≈ 3%
from its average, or unreadable) refuses settlement, with no timeout: the week
waits until the price is sound again, or until the timelock replaces the
pricer. Halting is the safe side; before this rule, moving the price in the
settling transaction after the three-day grace let a week emit its whole token
cap where its value cap allowed a small fraction of it.

### Decisions

| # | Decision | By |
|---|---|---|
| D1 | Supply 1,000,000,000 FEAST; 65% pool / 20% team / 14.2% emissions / 0.8% genesis partners (the 0.8% out of the 15%) | owner (rulings 1, Q14); supply to be confirmed |
| D2 | Team vesting: **no cliff**, 36 × 30.4375 days linear from the window's close; beneficiary transferable, renounce disabled; never delegates, so never votes | owner, 2026-09-11 |
| D3 | Every ledger track counts the whole fee — traders by fees paid, creators by the fees their coins earned whatever split they chose, referrers by the fees their referrals paid whatever commission (including none) | coordinator (Q3, Q4) |
| D4 | A referrer who is the payer is no referral at all (no commission, no credit); payer = `tx.origin` | owner ruling 5; coordinator (Q5, Q10) |
| D5 | Ledger weeks turn at Monday 00:00 UTC; the ledger is a separate contract | coordinator (Q9, §6.1) |
| D6 | The platform coin's pool may be gated at most 14 days, enforced by the hook; the window's own swap is recorded nowhere and emits no `Trade` | coordinator |
| D7 | The platform's fee share leaves the hook as the asset it accrued in, to the genesis-named sink, bounded per call; the sink sells it by **descending-price redemption** (no oracle, no route), burning the platform coin it is paid in | plan C2; owner (Q16) |
| D8 | **The internal fill** (the v1.1 floor's layer 2): an exact-input sale is filled from the coin's own buy-and-burn bucket at spot, inside the TWAP bound and ONE allowance shared with `buyBackAndBurn`; it settles in vault claims (nothing physical moves on the swap path) and the coin burns in a separate call | owner (Q15); the claims form after internal audit rounds 2–3 |
| D9 | One `Trade` event per swap (and per buy-back) with the trader's own amounts; a metadata digest on every coin, written at launch | owner (Q24, Q23) |
| D10 | Emission curve ∝ (53 − n); weights 40/45/15 for weeks 1–8, 20/65/15 after; an empty track emits nothing that week; an unpriceable quote waits 3 days after its week, then counts zero; the priced-quote list is fixed per pricer, replaceable only through the timelock | coordinator (Q6, Q7, Q11, Q13); owner (Q26) |
| D11 | **No Governor** (Q27): `TimelockController(3 days, proposer = TEAM_MULTISIG, executor = anyone, admin = itself)`, Snapshot off-chain. The timelock can reach exactly three levers on `FeastEmissions`, each bounded at the callee and effective from the next ledger week: the value ratio (5%–20%), a redirect of up to 50% of new weeks to a bridge escrow, and the pricer | owner (Q26, Q27) |
| D12 | FEAST's opening tick, the partners, `TARGET_NATIVE`, the team beneficiary and multisig, the window's start and the priced routes are placeholders; the scripts refuse to run while any is unset | coordinator (Q21) |
| D13 | The token-cap-only rule applies before launch only; after launch a moved or unpriceable platform price refuses settlement with no timeout, until the pricer lever fixes it. A route price too large to hold is unpriceable (grace, then zero), never a revert | coordinator, round-4 ruling |
| D14 | The redirect is its share of what a week actually emits, taken track by track, so empty tracks cannot push it past 50% | coordinator, round-4 ruling |
| D15 | Every priced quote is an 18-decimal token; the pricer refuses any other. A census of every planned quote at the pinned block (WBNB, USDT and the seven listed stock tokens) found no other; the factory stays open (Q2), and a coin quoted in a six-decimal token can sit outside the internal fill's exact domain and trade unfilled | coordinator, round-4 ruling |

### Declared risks

- **One track can be dominated.** Emissions are at most the value ratio of the
  week's fees and the platform burns 20%, so the protocol is always a net buyer —
  but that bounds the protocol, not a person. In weeks 1–8 a trader who refers
  themselves through a second address recovers more in FEAST than their net fee
  cost whenever referred fees are a small share of the week's fees: below ≈ 7% on
  someone else's coin, more loosely on their own coin, where half the fee comes
  back as the creator's remainder. One referral-track takeover is worth at most
  40% of the week's emission, i.e. 6% of that week's total fee value. The owner's
  ruling (no per-address cap; `referrer ≠ payer` the only rule) accepts this.
- **Settlement prices** are a ten-minute average on the pinned pools, at a moment
  the settle caller chooses; the deviation bound limits spot manipulation to
  ≈ 3%, and sustaining a false average on a thin pool costs real money for a share
  of one track.
- **Pre-launch weeks** pay at the full token cap with no price check (Q25): the
  owner's reasoning is that earning FEAST requires paid trading volume. A trader
  who dominates the traders' track before the TGE takes the largest share of the
  largest weekly caps.
- **Settlement can be held up, not bent** (round 4). Settlement is
  permissionless, so after launch anyone can delay one settle attempt by paying to
  move the platform coin's price more than ≈ 3% in the same block. It has to be
  paid for again at every attempt, and the average converges to a sustained move,
  so the refusal is temporary; no mitigation in this unit.
- **The sink sells without a floor before its first sale**: if nobody takes an
  asset that is genuinely on offer for days, its price falls towards zero. Once
  an asset has sold, its price does not fall below the last sale's price halved
  six times — that sale's price weighted by the share of the lot it took, so
  buying one unit of a million cannot set a floor as if the million had sold —
  and **that floor itself halves every 24 hours after the sale that set it**
  (v1.6.2). **A later sale may RAISE that floor and never lowers it, and a sale
  that does not raise it does not restart its clock either** (v1.6.3): before
  that, a one-wei purchase overwrote the floor a real sale had set and sent the
  remainder back to halving hourly. "The last sale's" therefore means the last
  sale that RAISED the floor, not merely the last sale. Both of those sentences
  are exact in real numbers; the contract reads the floor with a shift and a
  truncated linear step, so what it keeps is within four raw price units of the
  first and one raw price unit of the second — `audit/invariants.yaml` P19 states
  both bounds, and `docs/plan.md` §6d says what they are worth. Opening a new
  descent clears the floor: a floor is what a sale said about
  the lot its own descent priced, and it says nothing about the next one. So a lot the market has left behind — an asset that fell, or a
  platform coin that rose, more than sixty-fourfold since it last sold — comes
  back within reach in days rather than never. Without the floor's own clock one
  sale pins an asset above what anyone will pay for it permanently, and nothing
  in this system has a handle to unpin it.
- **The sink opens when the launch window closes** (v1.6.2). It is deployed at
  the factory's opening, against the coin's predicted address; genesis creates
  the coin later, and even then the whole supply sits in a gated pool, an
  unsettled window and unstarted vesting until the window closes. Every take is
  paid in that coin, so no descent starts before that moment — a price that falls
  while nobody on earth can pay it is a timer, not a market. Genesis fixes that
  moment once, by naming the launch window: the sink checks that the window says
  it is one and that it serves this coin, and reads its close. There is no time
  for anyone to choose, and no second naming. The naming is its own transaction
  in the launch script, immediately after the one that creates the coin — a
  script broadcasts each call separately — and the script refuses to call the
  launch finished until it has landed. If it never lands the sink stays shut,
  which is the safe way round, and the key can still complete it: its one power
  here is spent by being used, not by time passing.
- **A descent prices the lot it was opened over** (v1.6.2). The clock cannot run
  on an empty lot: a lot must hold something to be opened, and a lot holding at
  least twice what it held when its descent began — every refill into an emptied
  lot included — is priced from the top again until someone opens a descent over
  it. Three consequences are declared rather than hidden (`docs/plan.md` §B9):
  a refill *smaller* than the lot it lands in is sold at the price the standing
  descent has reached, so an attacker who leaves at least as much of the asset
  here as the next release will bring can run the price down over their own
  stake — a stake anyone may take from them at that same price for the whole
  descent; a descent can be reset to the top, either by donating enough of the
  asset to double the lot or by buying enough of it to halve what the descent
  priced, which denies a waiting taker for the platform coin the purchase burns —
  a cost that does not grow with repetition and can be less than the sale it
  postpones, though every unit that leaves was bought at the sink's own published
  price; after a lot is taken to empty the next one starts at the top again,
  about 64 hours above parity for an 18-decimal asset and an hour more for every
  halving below parity it is worth, accumulating while it descends; and an asset
  whose issuer can burn a holder's balance can shrink a lot below what its
  descent priced, which the sink cannot see between two of its own writes — until
  someone reopens the lot, a later arrival bringing it back to between once and
  twice the recorded size revives that descent. Anyone may reopen it, and the
  platform runs a keeper that does.
