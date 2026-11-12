# -*- coding: utf-8 -*-
InitLot = 0.02
MartinMult = 1.5
StepPoints = 100
point = 0.01
step_price = StepPoints * point
gold = 2650.0
equity_usd = 1000.0  # 100000 USC

lots = []
L = InitLot
for i in range(20):
    lots.append(L)
    L *= MartinMult


def loss_at_layer(k, offset, step):
    loss = 0.0
    for j in range(k):
        dist = (offset - j) * step
        if dist < 0:
            dist = 0
        loss += lots[j] * 100 * dist
    return loss


def margin_usd(total_lot, leverage, price=gold):
    return total_lot * 100 * price / leverage


def run(point_size, leverages):
    step = StepPoints * point_size
    print(f"\n=== point={point_size}, step_price=${step} per grid ===")
    for lev in leverages:
        print(f"\nLeverage 1:{lev}")
        print("layer pts move$ lot_i total_lot float$ floatUSC equity$ margin$ free$")
        for k in range(1, 16):
            offset = k - 1
            pts = offset * StepPoints
            total_lot = sum(lots[:k])
            fl = loss_at_layer(k, offset, step)
            eq = equity_usd - fl
            mg = margin_usd(total_lot, lev)
            free = eq - mg
            flag = " STOP" if (free <= 0 or eq <= 0) else ""
            print(
                f"{k:2d} {pts:5d} {offset*step:6.2f} {lots[k-1]:7.4f} {total_lot:8.4f} "
                f"{fl:8.2f} {fl*100:9.1f} {eq:8.2f} {mg:8.2f} {free:8.2f}{flag}"
            )
            if free <= 0 or eq <= 0:
                print(f">>> Cannot hold around {pts} points adverse (layer {k})")
                break


run(0.01, [100, 200, 500])
run(0.001, [100, 200, 500])
