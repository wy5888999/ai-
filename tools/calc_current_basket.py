# -*- coding: utf-8 -*-
"""从截图当前空单仓位估算：间距100、继续马丁1.5、不动手时还能抗多少点。"""

# 截图空单手数（由小到大 / 马丁链）
sell_lots = [0.02, 0.03, 0.05, 0.08, 0.12, 0.18, 0.27, 0.41, 0.62, 0.93]
# 账户（USC）
equity = 103266.95
margin = 2374.51
free = 100892.44
# 假设两位报价：100点 = 1 美元
point = 0.01
step_points = 100
step_price = step_points * point  # 1.0
martin = 1.5

# 标准黄金：盈亏(USD)=手数*100*价格变动；USC=USD*100
# 即每逆向 1 美元，亏损 USC = 总空单手数 * 100 * 1 * 100 = 手数*10000
# 每逆向 1 点(0.01)，亏损 USC = 手数 * 100 * 0.01 * 100 = 手数 * 100


def loss_usc_per_point(total_sell_lot: float) -> float:
    return total_sell_lot * 100.0  # USC / point (point=0.01)


def loss_usc_per_dollar(total_sell_lot: float) -> float:
    return total_sell_lot * 100.0 * 100.0  # = lot * 10000 USC


print("当前空单合计手数:", round(sum(sell_lots), 4))
print("当前可用预付款 USC:", free)
cur_lot = sum(sell_lots)
per_pt = loss_usc_per_point(cur_lot)
# 冻结仓位、不再加仓
pts_freeze = free / per_pt
print("\n[A] 不再加仓（仓位冻住）")
print(f"  每逆向1点约亏: {per_pt:.2f} USC")
print(f"  可用保证金打光大约: {pts_freeze:.0f} 点  (约 {pts_freeze*point:.2f} 美元)")

# 继续按100点加仓马丁
print("\n[B] EA继续跑：每涨100点再加一仓×1.5（你一直不动）")
lots = list(sell_lots)
# 从当前价开始，每涨100点加仓，同时这段浮亏累积
# 简化：在每一格边界结算
price_up = 0.0  # 相对当前已逆向的美元
equity_left = equity
# 保证金随手数增加：用当前 margin/手数 估算
margin_per_lot = margin / cur_lot if cur_lot else 0

bust_points = None
print(f"{'逆向点':>8} {'美元':>8} {'新开手':>8} {'总空手':>8} {'本段亏USC':>10} {'累计亏':>10} {'约净值':>10} {'约保证金':>10} {'约可用':>10}")

cum_loss = equity - 103266.95  # 0
cum_loss = 0.0
rel_points = 0
for step in range(0, 30):
    # 先检查从上一格走到这一格（100点）的亏损（用走之前的总手数）
    if step > 0:
        total = sum(lots)
        seg_loss = loss_usc_per_point(total) * step_points
        cum_loss += seg_loss
        rel_points += step_points
        eq = equity - cum_loss
        mg = margin_per_lot * total
        fr = eq - mg
        new_lot = lots[-1] * martin
        print(
            f"{rel_points:8d} {rel_points*point:8.2f} {new_lot:8.4f} {total:8.4f} "
            f"{seg_loss:10.1f} {cum_loss:10.1f} {eq:10.1f} {mg:10.1f} {fr:10.1f}"
            + ("  <<危险" if fr <= 0 or eq <= mg * 0.5 else "")
        )
        if fr <= 0 or eq <= 0:
            bust_points = rel_points
            print(f">>> 大约在再逆向 {bust_points} 点 时可用/净值顶不住")
            break
        # 开新仓
        lots.append(new_lot)
    else:
        # step0 当前状态
        total = sum(lots)
        print(
            f"{0:8d} {0:8.2f} {'(当前)':>8} {total:8.4f} "
            f"{0:10.1f} {0:10.1f} {equity:10.1f} {margin:10.1f} {free:10.1f}"
        )

if bust_points is None:
    print("30格内未爆（少见）")

print("\n说明: 按标准 XAU 合约100、USC=美元×100、点值0.01 估算；")
print("实际强平线看券商（常见预付款维持率50%/20%），可能比「可用=0」更早或略晚。")
