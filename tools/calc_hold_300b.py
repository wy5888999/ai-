# -*- coding: utf-8 -*-
equity_usd = 1000.0
contract = 100
gold = 4300.0
lev = 500
target = 300.0


def sim(init, martin, step, maxL, note=""):
    lots = []
    L = init
    n = min(maxL, int(target / step) + 1)
    for _ in range(n):
        lots.append(L)
        L *= martin
    offset = n - 1
    move = offset * step
    fl = sum(lots[j] * contract * (offset - j) * step for j in range(n))
    total = sum(lots)
    mg = total * contract * gold / lev
    remain = max(0.0, target - move)
    extra = total * contract * remain
    eq = equity_usd - fl - extra
    free = eq - mg
    ok = free > 100 and eq > 100
    status = "OK" if ok else "NO"
    print(
        f"{note} | init={init} m={martin} step={step} maxL={maxL} "
        f"layers={n} span={move} lot={total:.3f} loss={fl+extra:.0f} "
        f"eq={eq:.0f} free={free:.0f} {status}"
    )


print("full cover 300")
for s in [60, 70, 80, 100]:
    sim(0.01, 1.0, s, 20, "equal")
sim(0.01, 1.0, 100, 4, "4 layers step100")
sim(0.01, 1.0, 75, 5, "5 layers step75")

print("\nsoft: small grid then freeze to 300")
for step, maxL in [(10, 4), (15, 4), (20, 4), (25, 3), (30, 3), (20, 3)]:
    sim(0.01, 1.0, step, maxL, "cap")

print("\nmild martin capped")
sim(0.01, 1.2, 40, 4, "m1.2")
sim(0.01, 1.2, 50, 4, "m1.2")
sim(0.01, 1.3, 50, 3, "m1.3")
