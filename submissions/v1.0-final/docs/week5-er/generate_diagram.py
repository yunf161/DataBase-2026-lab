"""从同一份实体/联系定义生成第五周 draw.io 源图和 SVG 导出图。"""

from __future__ import annotations

from dataclasses import dataclass
from html import escape
from pathlib import Path
from xml.etree import ElementTree as ET


OUT = Path(__file__).resolve().parent
WIDTH, HEIGHT = 2350, 1390
BOX_W, BOX_H = 280, 190


@dataclass(frozen=True)
class Entity:
    name: str
    title: str
    x: int
    y: int
    fields: tuple[str, ...]
    kind: str = "normal"  # association / proposed


@dataclass(frozen=True)
class Relation:
    code: str
    source: str
    target: str
    label: str
    points: tuple[tuple[int, int], ...]
    label_at: tuple[int, int]
    proposed: bool = False


# 中文说明只放在关键处：这里的键标记和业务规则表必须同步修改。
ENTITIES = (
    Entity("Supplier", "供应商 Supplier", 80, 100,
           ("PK SupplierID", "AK SupplierCode", "SupplierName", "ContactName / Phone")),
    Entity("PurchaseOrder", "采购单 PurchaseOrder", 510, 100,
           ("PK PurchaseID", "AK PurchaseNo", "FK SupplierID / EmployeeID", "Status / TotalAmount")),
    Entity("Employee", "员工 Employee", 1000, 100,
           ("PK EmployeeID", "AK EmployeeNo", "EmployeeName / RoleName", "Status")),
    Entity("SaleOrder", "销售单 SaleOrder", 1490, 100,
           ("PK SaleID", "AK SaleNo", "FK EmployeeID", "Status / PaymentMethod")),
    Entity("Member", "会员 Member（拟议）", 1970, 100,
           ("拟 PK MemberID", "拟 AK MemberNo", "MemberName / Phone", "拟 SaleOrder.MemberID FK"), "proposed"),
    Entity("Category", "分类 Category", 80, 550,
           ("PK CategoryID", "AK CategoryCode", "FK ParentID（可空）", "CategoryName / Status")),
    Entity("Product", "商品 Product", 650, 550,
           ("PK ProductID", "AK SKU；Barcode 可空 UQ", "FK CategoryID", "ProductName / SalePrice")),
    Entity("Inventory", "库存 Inventory", 1190, 550,
           ("PK+FK ProductID", "Quantity", "MinQuantity", "业务目标：每商品一行")),
    Entity("PurchaseItem", "采购明细 PurchaseItem", 510, 1050,
           ("PK PurchaseItemID", "复合 AK (PurchaseID, ProductID)", "FK PurchaseID / ProductID", "Quantity / UnitCost"), "association"),
    Entity("SaleItem", "销售明细 SaleItem", 1490, 1050,
           ("PK SaleItemID", "复合 AK (SaleID, ProductID)", "FK SaleID / ProductID", "Quantity / UnitPrice"), "association"),
    Entity("InventoryLog", "库存流水 InventoryLog", 1970, 1050,
           ("PK LogID", "FK ProductID", "FK EmployeeID（可空）", "ChangeQuantity / BusinessNo")),
)

# 斜杠前后依次是「一个 source 对应几个 target」与反向基数。
# 不要把草稿单标成 1..N：确认/结算时的条件约束写在业务规则表。
RELATIONS = (
    Relation("R01", "Category", "Category", "上下级 0..N / 0..1",
             ((80, 590), (30, 590), (30, 510), (170, 510), (170, 550)), (120, 485)),
    Relation("R02", "Category", "Product", "归类 0..N / 1..1",
             ((360, 645), (650, 645)), (505, 620)),
    Relation("R03", "Supplier", "PurchaseOrder", "供货 0..N / 1..1",
             ((360, 195), (510, 195)), (435, 340)),
    Relation("R04", "Employee", "PurchaseOrder", "采购经办 0..N / 1..1",
             ((1000, 195), (790, 195)), (895, 340)),
    Relation("R05", "PurchaseOrder", "PurchaseItem", "采购包含 0..N / 1..1",
             ((510, 245), (430, 245), (430, 1145), (510, 1145)), (430, 820)),
    Relation("R06", "Product", "PurchaseItem", "被采购 0..N / 1..1",
             ((710, 740), (710, 1050)), (710, 900)),
    Relation("R07", "Employee", "SaleOrder", "销售经办 0..N / 1..1",
             ((1280, 195), (1490, 195)), (1385, 340)),
    Relation("R08", "SaleOrder", "SaleItem", "销售包含 0..N / 1..1",
             ((1770, 245), (1840, 245), (1840, 1145), (1770, 1145)), (1840, 810)),
    Relation("R09", "Product", "SaleItem", "被售出 0..N / 1..1",
             ((930, 710), (1090, 870), (1600, 870), (1600, 1050)), (1300, 845)),
    Relation("R10", "Product", "Inventory", "当前库存 业务1..1 / 1..1*",
             ((930, 645), (1190, 645)), (1060, 795)),
    Relation("R11", "Product", "InventoryLog", "库存变化 0..N / 1..1",
             ((900, 550), (900, 430), (2110, 430), (2110, 1050)), (1690, 405)),
    Relation("R12", "Employee", "InventoryLog", "执行变化 0..N / 0..1",
             ((1140, 100), (1140, 50), (2310, 50), (2310, 1145), (2250, 1145)), (2070, 25)),
    Relation("R13", "Member", "SaleOrder", "会员购买 0..N / 0..1（拟）",
             ((1970, 195), (1770, 195)), (1870, 340), True),
)


def add_diagram_cell(root: ET.Element, entity: Entity) -> None:
    fill = {"normal": "#ffffff", "association": "#eaf5ed", "proposed": "#eef4ff"}[entity.kind]
    dashed = "dashed=1;dashPattern=8 5;" if entity.kind == "proposed" else ""
    lines = [f"<b>{escape(entity.title)}</b>", *map(escape, entity.fields)]
    cell = ET.SubElement(root, "mxCell", {
        "id": entity.name, "value": "<br>".join(lines), "vertex": "1", "parent": "1",
        "style": f"rounded=1;whiteSpace=wrap;html=1;align=left;verticalAlign=middle;"
                 f"spacingLeft=14;fontSize=15;fillColor={fill};strokeColor=#35536b;{dashed}",
    })
    ET.SubElement(cell, "mxGeometry", {
        "x": str(entity.x), "y": str(entity.y), "width": str(BOX_W),
        "height": str(BOX_H), "as": "geometry",
    })


def write_drawio() -> None:
    mxfile = ET.Element("mxfile", {"host": "app.diagrams.net", "type": "device"})
    diagram = ET.SubElement(mxfile, "diagram", {"name": "Week5 ER", "id": "week5-er"})
    model = ET.SubElement(diagram, "mxGraphModel", {
        "dx": "2350", "dy": "1390", "grid": "1", "gridSize": "10", "page": "1",
        "pageScale": "1", "pageWidth": str(WIDTH), "pageHeight": str(HEIGHT),
    })
    root = ET.SubElement(model, "root")
    ET.SubElement(root, "mxCell", {"id": "0"})
    ET.SubElement(root, "mxCell", {"id": "1", "parent": "0"})
    for cell_id, value, x, y, width, height, size in (
        ("diagram-title", "校园小卖部 v0.1 ER 模型", 70, 5, 600, 50, 27),
        ("diagram-subtitle", "实线＝已有外键；虚线＝第六周拟议会员；R 编号对应业务规则表", 70, 52, 1000, 35, 15),
        ("diagram-legend", "PK 主码　AK 候选码　FK 外码　UQ 可空唯一。a / b 按业务规则表左→右读。<br>"
         "* 商品→库存业务期望 1..1，现有约束仅保证 0..1；草稿订单明细 0..N，确认或结算时由过程要求 1..N。",
         80, 1290, 2180, 75, 15),
    ):
        cell = ET.SubElement(root, "mxCell", {
            "id": cell_id, "value": value, "vertex": "1", "parent": "1",
            "style": f"text;html=1;align=left;verticalAlign=middle;fontSize={size};"
                     "fontColor=#183047;whiteSpace=wrap;",
        })
        ET.SubElement(cell, "mxGeometry", {"x": str(x), "y": str(y),
                                        "width": str(width), "height": str(height), "as": "geometry"})
    for entity in ENTITIES:
        add_diagram_cell(root, entity)
    for relation in RELATIONS:
        cell = ET.SubElement(root, "mxCell", {
            "id": relation.code,
            "value": "",
            "edge": "1", "parent": "1", "source": relation.source,
            "target": relation.target,
            "style": "edgeStyle=orthogonalEdgeStyle;rounded=0;orthogonalLoop=1;"
                     "html=1;fontSize=13;labelBackgroundColor=#ffffff;"
                     + ("dashed=1;dashPattern=8 5;strokeColor=#2866bc;" if relation.proposed
                        else "strokeColor=#43627a;"),
        })
        geometry = ET.SubElement(cell, "mxGeometry", {"relative": "1", "as": "geometry"})
        points = ET.SubElement(geometry, "Array", {"as": "points"})
        # 中间折点保留为可拖动的 draw.io waypoint。
        for x, y in relation.points[1:-1]:
            ET.SubElement(points, "mxPoint", {"x": str(x), "y": str(y)})
        # 独立文字框让 draw.io 中的标注位置与 SVG 一致，且可以手动拖动。
        label = f"{relation.code} {relation.label}"
        label_width = max(160, len(label) * 13)
        x, y = relation.label_at
        label_cell = ET.SubElement(root, "mxCell", {
            "id": f"label-{relation.code}", "value": escape(label),
            "vertex": "1", "parent": "1",
            "style": "text;html=1;align=center;verticalAlign=middle;fontSize=15;"
                     "fontStyle=1;fillColor=#f8fbfd;strokeColor=none;whiteSpace=wrap;",
        })
        ET.SubElement(label_cell, "mxGeometry", {
            "x": str(x - label_width // 2), "y": str(y - 22),
            "width": str(label_width), "height": "28", "as": "geometry",
        })
    ET.indent(mxfile, space="  ")
    ET.ElementTree(mxfile).write(OUT / "week5-er.drawio", encoding="utf-8", xml_declaration=True)


def write_svg() -> None:
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" '
        f'viewBox="0 0 {WIDTH} {HEIGHT}">',
        '<style>text{font-family:"Microsoft YaHei","Noto Sans CJK SC",sans-serif;fill:#183047}'
        '.title{font-size:27px;font-weight:700}.subtitle{font-size:15px;fill:#486174}'
        '.entity-title{font-size:17px;font-weight:700}.field{font-size:15px}'
        '.edge-label{font-size:15px;font-weight:600}</style>',
        f'<rect x="0" y="0" width="{WIDTH}" height="{HEIGHT}" fill="#f8fbfd"/>',
        '<text x="70" y="42" class="title">校园小卖部 v0.1 ER 模型</text>',
        '<text x="70" y="70" class="subtitle">实线＝已有外键　虚线＝第六周拟议会员；R 编号与业务规则表对应</text>',
    ]
    for relation in RELATIONS:
        coords = " ".join(f"{x},{y}" for x, y in relation.points)
        color = "#2866bc" if relation.proposed else "#43627a"
        dash = ' stroke-dasharray="9 6"' if relation.proposed else ""
        parts.append(f'<polyline points="{coords}" fill="none" stroke="{color}" '
                     f'stroke-width="2.4" stroke-linejoin="round"{dash}/>' )
    for entity in ENTITIES:
        fill = {"normal": "#ffffff", "association": "#eaf5ed", "proposed": "#eef4ff"}[entity.kind]
        dash = ' stroke-dasharray="9 6"' if entity.kind == "proposed" else ""
        parts.append(f'<rect x="{entity.x}" y="{entity.y}" width="{BOX_W}" height="{BOX_H}" '
                     f'rx="12" fill="{fill}" stroke="#35536b" stroke-width="2"{dash}/>' )
        parts.append(f'<text x="{entity.x + 14}" y="{entity.y + 31}" class="entity-title">'
                     f'{escape(entity.title)}</text>')
        for index, field in enumerate(entity.fields):
            parts.append(f'<text x="{entity.x + 14}" y="{entity.y + 65 + index * 26}" '
                         f'class="field">{escape(field)}</text>')
    for relation in RELATIONS:
        label = f"{relation.code} {relation.label}"
        x, y = relation.label_at
        label_width = max(160, len(label) * 13)
        parts.append(f'<rect x="{x - label_width // 2}" y="{y - 19}" '
                     f'width="{label_width}" height="25" rx="5" fill="#f8fbfd" opacity="0.96"/>')
        parts.append(f'<text x="{x}" y="{y}" class="edge-label" text-anchor="middle">'
                     f'{escape(label)}</text>')
    parts.extend([
        '<rect x="80" y="1290" width="2180" height="72" rx="8" fill="#e9f1f5"/>',
        '<text x="98" y="1320" class="subtitle">标记：PK 主码　AK 候选码　FK 外码　UQ 可空唯一。联系标签“a / b”按规则表左→右读：每条左端对应 a 条右端，反向为 b。</text>',
        '<text x="98" y="1347" class="subtitle">* 商品→库存业务期望 1..1，现有 PK+FK 实际只保证 0..1；草稿订单明细 0..N，确认或结算时由过程要求 1..N。</text>',
        '</svg>',
    ])
    (OUT / "week5-er.svg").write_text("\n".join(parts), encoding="utf-8")


if __name__ == "__main__":
    write_drawio()
    write_svg()
    print("已生成 week5-er.drawio 和 week5-er.svg")
