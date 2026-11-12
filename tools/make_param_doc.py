# -*- coding: utf-8 -*-
from pathlib import Path
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.oxml import OxmlElement


def set_run_font(run, name="微软雅黑", size=11, bold=False, color=None):
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.name = name
    r = run._element
    rPr = r.get_or_add_rPr()
    rFonts = rPr.find(qn("w:rFonts"))
    if rFonts is None:
        rFonts = OxmlElement("w:rFonts")
        rPr.insert(0, rFonts)
    rFonts.set(qn("w:ascii"), name)
    rFonts.set(qn("w:hAnsi"), name)
    rFonts.set(qn("w:eastAsia"), name)
    if color:
        run.font.color.rgb = color


def add_heading_cn(doc, text, level=1):
    p = doc.add_heading(text, level=level)
    for run in p.runs:
        set_run_font(run, size=(16 if level == 1 else 13), bold=True)
    return p


def add_para(doc, text, size=11, bold=False):
    p = doc.add_paragraph()
    run = p.add_run(text)
    set_run_font(run, size=size, bold=bold)
    p.paragraph_format.space_after = Pt(6)
    return p


def set_cell_text(cell, text, bold=False, size=10):
    cell.text = ""
    p = cell.paragraphs[0]
    run = p.add_run(text)
    set_run_font(run, size=size, bold=bold)


def shade_cell(cell, hex_color):
    tc = cell._tc
    tcPr = tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:fill"), hex_color)
    shd.set(qn("w:val"), "clear")
    tcPr.append(shd)


def add_table(doc, rows):
    table = doc.add_table(rows=1 + len(rows), cols=3)
    table.style = "Table Grid"
    hdr = table.rows[0].cells
    set_cell_text(hdr[0], "参数名", True)
    set_cell_text(hdr[1], "默认值", True)
    set_cell_text(hdr[2], "说明", True)
    for c in hdr:
        shade_cell(c, "1F3A5F")
        for p in c.paragraphs:
            for run in p.runs:
                run.font.color.rgb = RGBColor(255, 255, 255)
                set_run_font(run, size=10, bold=True)
    for i, (name, default, desc) in enumerate(rows, start=1):
        set_cell_text(table.rows[i].cells[0], name, True, 10)
        set_cell_text(table.rows[i].cells[1], default, False, 10)
        set_cell_text(table.rows[i].cells[2], desc, False, 10)
    doc.add_paragraph()


def main():
    doc = Document()
    section = doc.sections[0]
    section.top_margin = Cm(2)
    section.bottom_margin = Cm(2)
    section.left_margin = Cm(2.2)
    section.right_margin = Cm(2.2)

    title = doc.add_paragraph()
    title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = title.add_run("纯马丁 EA 参数与操作说明")
    set_run_font(r, size=22, bold=True, color=RGBColor(0x1F, 0x3A, 0x5F))

    sub = doc.add_paragraph()
    sub.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = sub.add_run(
        "文件：XAUUSD_Grid_EA.mq5　版本：v6.52　品种：XAUUSD（美分账户）"
    )
    set_run_font(r, size=11, color=RGBColor(0x55, 0x55, 0x55))

    add_para(
        doc,
        "核心：全人工开仓（不自动买入/加仓）；主号点「入场多/入场空」同步从号；"
        "单边最多 15 层；AI 只显示方向不下单；篮子固定止盈止损；无北京时段限制。",
    )

    add_heading_cn(doc, "一、运行逻辑", 1)
    for b in [
        "挂上 EA 后不会自动开仓。必须主号点面板「入场多」或「入场空」才开一单。",
        "再点一次同按钮 = 该边再加一层（手数按 MartinMult 递增，如 0.01×1.3）。",
        "单边层数达到 MaxLayers（默认 15）后拒开。",
        "主号点击后写入 Common\\Files\\XAU_Martin_Entry.sig；从号自动跟开同一边。",
        "止盈：多空合计浮盈 ≥ BasketTP 全平。止损：合计浮亏 ≤ BasketSL_Money 全平并冷却。",
        "AI（DeepSeek）：面板显示方向与置信度，绝不根据 AI 自动下单或冻结开仓。",
        "新闻过滤开启时，新闻窗口内仍可能拦截新开仓；平仓/止盈止损不受影响。",
        "暂停：停人工开仓与跟随开仓；止盈止损仍生效。",
    ]:
        p = doc.add_paragraph(style="List Bullet")
        run = p.add_run(b)
        set_run_font(run, size=11)

    add_heading_cn(doc, "二、多账号绑定", 1)
    for b in [
        "全账户仅 1 个勾选 SharedConfigMaster=true（主号，负责改参与点入场）。",
        "其余账号：UseSharedConfig=true，SharedConfigMaster=false（从号）。",
        "参数文件：Common\\Files\\XAU_Martin_Shared.cfg（主号写、从号读）。",
        "入场信号：Common\\Files\\XAU_Martin_Entry.sig（含 EntryId + Side=BUY/SELL）。",
        "从号面板显示「跟多/跟空」，不能发令，只会跟随主号。",
        "升级后建议主号删旧 cfg/sig 再挂一次，或确认 MaxLayers=15 已写入共享文件。",
    ]:
        p = doc.add_paragraph(style="List Bullet")
        run = p.add_run(b)
        set_run_font(run, size=11)

    add_heading_cn(doc, "三、面板按钮", 1)
    add_table(
        doc,
        [
            ("入场多", "—", "主号：开/加一层多单，并广播从号跟随。"),
            ("入场空", "—", "主号：开/加一层空单，并广播从号跟随。"),
            ("平多", "—", "平掉本 EA 多单。"),
            ("平空", "—", "平掉本 EA 空单。"),
            ("暂停/恢复", "—", "暂停后不再开仓；恢复后可再点入场。"),
            ("全部平仓", "—", "平掉本 EA 全部仓位。"),
        ],
    )

    add_heading_cn(doc, "【零】AI 方向提示", 1)
    add_table(
        doc,
        [
            ("UseExternalAI", "true", "是否读外部 DeepSeek 信号（仅显示）。"),
            ("AiSignalMaxAgeSec", "180", "信号过期秒数，过期显示无信号。"),
            ("AiSnapshotSec", "5", "写行情快照间隔，供 ai_signal_bridge.py 读取。"),
        ],
    )
    add_para(
        doc,
        "桥接：运行 tools\\ai_signal_bridge.py；需配置 data\\deepseek_config.json。"
        "信号文件：Common\\Files\\ai\\signal.txt；快照：ai\\snapshot.txt。",
    )

    add_heading_cn(doc, "【一】纯马丁", 1)
    add_table(
        doc,
        [
            ("InitLot", "0.01", "首笔手数；每边第一单用此手数。"),
            ("MartinMult", "1.3", "人工再点加仓时：下一笔 ≈ 上一笔 × 本值。"),
            ("GridStepUSD_1_20", "1.0", "间距参数（全人工开仓时仅作面板参考显示）。"),
            ("GridStepUSD_21_50", "2.0", "同上。"),
            ("GridStepUSD_After50", "5.0", "同上。"),
            ("AddCooldownSec", "15", "同边连点最短间隔（秒），防抖。"),
            ("MaxLayers", "15", "单边最多层数，达到后拒开。"),
            ("BasketTP", "50.0", "篮子止盈（USC）。多空合计浮盈达到即全平。"),
            ("BasketSL_Money", "-4500.0", "篮子止损（USC）。合计浮亏达到即全平。"),
            ("BasketSL_CooldownSec", "300", "止损后禁止新开仓的冷却秒数。"),
            ("MartinDirection", "2", "【废弃】固定双边，忽略。"),
            ("GridDirection", "2", "【废弃】"),
            ("FirstBothSides", "true", "【废弃】"),
        ],
    )

    add_heading_cn(doc, "【二】新闻", 1)
    add_table(
        doc,
        [
            ("UseNewsFilter", "true", "新闻窗口内是否禁止新开仓。"),
            ("NewsBeforeMin", "30", "新闻前冻结分钟。"),
            ("NewsAfterMin", "15", "新闻后冻结分钟。"),
            ("NewsRefreshSec", "30", "日历刷新间隔秒。"),
        ],
    )

    add_heading_cn(doc, "【三】公共", 1)
    add_table(
        doc,
        [
            ("MagicBase", "88000", "魔术号；同品种多 EA 须不同。"),
            ("OrderCommentText", "美分马丁", "订单注释前缀。"),
            ("MaxSpreadPoints", "5000", "点差过大不开新仓。"),
            ("BgImageFile", "（空）", "可选面板背景 bmp。"),
        ],
    )

    add_heading_cn(doc, "【四】共享配置", 1)
    add_table(
        doc,
        [
            ("UseSharedConfig", "true", "启用 Common 共享参数与入场同步。"),
            ("SharedConfigMaster", "false", "是否主号（全场仅 1 个 true）。"),
            ("SharedConfigFile", "XAU_Martin_Shared.cfg", "参数共享文件名。"),
            ("SharedConfigReloadSec", "3", "从号重读参数间隔秒。"),
            ("SharedEntryFile", "XAU_Martin_Entry.sig", "入场信号文件名。"),
        ],
    )

    add_heading_cn(doc, "四、操作流程（20 账号）", 1)
    for b in [
        "所有账号挂同一 EA（v6.52），品种 XAUUSD。",
        "指定 1 个主号：SharedConfigMaster=true；其余 false。",
        "主号按需改 InitLot / MaxLayers / BasketTP / BasketSL 等，写入共享 cfg。",
        "需要开多时主号点「入场多」；需要开空点「入场空」；从号自动跟。",
        "要加仓：主号再点同方向按钮（未满 15 层且过冷却）。",
        "看 AI 方向仅作参考，最终以人工点击为准。",
    ]:
        p = doc.add_paragraph(style="List Bullet")
        run = p.add_run(b)
        set_run_font(run, size=11)

    add_heading_cn(doc, "五、风险提示", 1)
    add_para(
        doc,
        "人工加仓仍会按马丁倍数放大手数；15 层累计手数不小。"
        "请按账户净值设置 BasketSL_Money 与 InitLot。"
        "历史表现不代表未来收益。",
    )

    out_dir = Path(r"F:\EA")
    out_cn = out_dir / ("\u7eaf\u9a6c\u4e01_EA_v6.52_\u53c2\u6570\u8bf4\u660e.docx")
    out_ascii = out_dir / "XAUUSD_Martin_EA_v6.52_ParamGuide.docx"

    for f in out_dir.glob("*.docx"):
        name = f.name
        if "ParamGuide" in name or "\u53c2\u6570\u8bf4\u660e" in name or "_EA_v6." in name:
            try:
                f.unlink()
            except OSError:
                pass

    doc.save(str(out_cn))
    doc.save(str(out_ascii))
    print("saved:", out_cn)
    print("saved:", out_ascii)


if __name__ == "__main__":
    main()
