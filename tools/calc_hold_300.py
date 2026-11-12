# -*- coding: utf-8 -*-
"""抗 300 美金（用户口径：1点=$1）参数测算，账户约 1000 USD = 100000 USC"""

equity_usd = 1000.0
target_move = 300.0  # 美元 = 用户的 300 点
contract = 100
gold = 4300.0
leverage = 500


def sim(init_lot, martin, step_usd, max_layers, label):
    """从空仓开始，每 step_usd 加一层，直到走满 target_move 或爆。"""
    lots = []
    L = init_lot
    layers_possible = int(target_move / step_usd) + 1
    n = min(max_layers, layers_possible)
    for i in range(n):
        lots.append(L)
        L *= martin

    # 走到最后一层开仓价：逆向 (n-1)*step
    offset = n - 1
    move = offset * step_usd
    float_loss = 0.0
    for j in range(n):
        dist = (offset - j) * step_usd
        float_loss += lots[j] * contract * dist

    total_lot = sum(lots)
    margin = total_lot * contract * gold / leverage
    equity = equity_usd - float_loss
    free = equity - margin

    # 若还有剩余距离到 300 且不能再加仓，按总手数继续亏
    remain = target_move - move
    extra = 0.0
    if remain > 0:
        extra = total_lot * contract * remain
    equity_at_300 = equity_usd - float_loss - extra
    margin_at_300 = margin  # 简化不再加仓
    free_at_300 = equity_at_300 - margin_at_300

    ok = free_at_300 > 0 and equity_at_300 > 50
    print(f"\n=== {label} ===")
    print(f"起手{init_lot} 马丁{martin} 间距{step_usd}点($) 最大层{max_layers}")
    print(f"实际层数{n} 铺满跨度${move:.0f} 总手数{total_lot:.4f}")
    print(f"铺满时浮亏${float_loss:.1f} 可用${free:.1f}")
    print(f"走到$300时净值${equity_at_300:.1f} 可用${free_at_300:.1f} -> {'可抗住' if ok else '抗不住'}")
    return ok


print("账户约$1000，目标单边抗$300（你的300点）")
# 当前危险参数
sim(0.02, 1.5, 1.0, 12, "当前：0.02/1.5/间距1")
# 方案
sim(0.01, 1.0, 20.0, 16, "方案A：等手数0.01 间距20点")
sim(0.01, 1.0, 30.0, 11, "方案B：等手数0.01 间距30点")
sim(0.01, 1.0, 50.0, 7, "方案C：等手数0.01 间距50点")
sim(0.01, 1.2, 25.0, 10, "方案D：轻马丁1.2 间距25点 限10层")
sim(0.01, 1.0, 60.0, 6, "方案E：等手数0.01 间距60点 6层覆盖300")
sim(0.01, 1.3, 30.0, 6, "方案F：马丁1.3 间距30 最多6层")
sim(0.01, 1.0, 15.0, 8, "方案G：等手数 间距15 只扛约120后停加仓")
