"""生成最终应用层 ER 补充图，保留第 5、6 周的核心业务 ER 图。"""

from __future__ import annotations

from dataclasses import dataclass
from html import escape
from pathlib import Path
from xml.etree import ElementTree as ET


OUT = Path(__file__).resolve().parent
WIDTH, HEIGHT = 1600, 900
BOX_WIDTH, BOX_HEIGHT = 360, 210


@dataclass(frozen=True)
class Entity:
    name: str
    title: str
    x: int
    y: int
    fields: tuple[str, ...]
    added_by_app: bool = False


@dataclass(frozen=True)
class Relation:
    code: str
    source: str
    target: str
    label: str
    points: tuple[tuple[int, int], tuple[int, int]]
    label_at: tuple[int, int]


ENTITIES = (
    Entity("Employee", "员工 Employee", 100, 130,
           ("PK EmployeeID", "AK EmployeeNo", "RoleName / Status")),
    Entity("AppUser", "应用账号 app.AppUser", 1080, 130,
           ("PK UserID；AK Username", "FK EmployeeID（可空、非空唯一）",
            "RoleName / Status", "PasswordHash / DisplayName"), True),
    Entity("SaleOrder", "销售单 dbo.SaleOrder", 100, 500,
           ("PK SaleID；AK SaleNo", "FK EmployeeID", "Status / TotalAmount")),
    Entity("SaleOwner", "订单归属 app.SaleOwner", 1080, 500,
           ("PK+FK SaleID", "FK UserID", "SubmittedAt（可空）", "CreatedAt"), True),
)

# 基数按 source → target / target → source 读取，不能按样例行数推断。
RELATIONS = (
    Relation("R07", "Employee", "SaleOrder", "经办销售 0..N / 1..1",
             ((280, 340), (280, 500)), (280, 435)),
    Relation("A01", "Employee", "AppUser", "员工账号 0..1 / 0..1*",
             ((460, 235), (1080, 235)), (770, 215)),
    Relation("A02", "AppUser", "SaleOwner", "创建订单 0..N / 1..1",
             ((1260, 340), (1260, 500)), (1260, 435)),
    Relation("A03", "SaleOrder", "SaleOwner", "归属记录 0..1 / 1..1**",
             ((460, 605), (1080, 605)), (770, 585)),
)


def write_drawio() -> None:
    root_file = ET.Element("mxfile", {"host": "app.diagrams.net", "type": "device"})
    diagram = ET.SubElement(root_file, "diagram", {"name": "Final app ER", "id": "app-er"})
    model = ET.SubElement(diagram, "mxGraphModel", {
        "dx": str(WIDTH), "dy": str(HEIGHT), "grid": "1", "page": "1",
        "pageScale": "1", "pageWidth": str(WIDTH), "pageHeight": str(HEIGHT),
    })
    root = ET.SubElement(model, "root")
    ET.SubElement(root, "mxCell", {"id": "0"})
    ET.SubElement(root, "mxCell", {"id": "1", "parent": "0"})

    for cell_id, value, x, y, width, height, size in (
        ("title", "校园小卖部最终应用层 ER 补充图", 70, 20, 1100, 48, 28),
        ("subtitle", "与第六周十张核心业务表 ER 图配套；黄色实体由第七至九周应用新增", 70, 70, 1370, 35, 17),
        ("legend", "PK 主码；AK 候选码；FK 外码。联系标签按 source→target / 反向读取。<br>"
         "* 顾客账号不关联员工；管理员/店员账号必须关联一名员工。员工可没有应用账号。<br>"
         "** 旧销售单可没有归属行；通过应用创建的新销售单由过程写入归属。账号不是会员实体。",
         80, 790, 1440, 95, 17),
    ):
        cell = ET.SubElement(root, "mxCell", {
            "id": cell_id, "value": value, "vertex": "1", "parent": "1",
            "style": f"text;html=1;align=left;verticalAlign=middle;fontSize={size};"
                     "fontColor=#183047;whiteSpace=wrap;",
        })
        ET.SubElement(cell, "mxGeometry", {
            "x": str(x), "y": str(y), "width": str(width), "height": str(height), "as": "geometry",
        })

    for entity in ENTITIES:
        lines = [f"<b>{escape(entity.title)}</b>", *map(escape, entity.fields)]
        cell = ET.SubElement(root, "mxCell", {
            "id": entity.name, "value": "<br>".join(lines), "vertex": "1", "parent": "1",
            "style": "rounded=1;whiteSpace=wrap;html=1;align=left;verticalAlign=middle;"
                     "spacingLeft=16;fontSize=17;strokeColor=#35536b;"
                     f"fillColor={'#fff2cc' if entity.added_by_app else '#ffffff'};",
        })
        ET.SubElement(cell, "mxGeometry", {
            "x": str(entity.x), "y": str(entity.y),
            "width": str(BOX_WIDTH), "height": str(BOX_HEIGHT), "as": "geometry",
        })

    for relation in RELATIONS:
        ET.SubElement(root, "mxCell", {
            "id": relation.code, "value": "", "edge": "1", "parent": "1",
            "source": relation.source, "target": relation.target,
            "style": "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;"
                     "strokeColor=#43627a;strokeWidth=2;",
        }).append(ET.Element("mxGeometry", {"relative": "1", "as": "geometry"}))
        label = f"{relation.code} {relation.label}"
        x, y = relation.label_at
        ET.SubElement(root, "mxCell", {
            "id": f"label-{relation.code}", "value": escape(label),
            "vertex": "1", "parent": "1",
            "style": "text;html=1;align=center;verticalAlign=middle;fontSize=16;"
                     "fontStyle=1;fillColor=#f8fbfd;strokeColor=none;whiteSpace=wrap;",
        }).append(ET.Element("mxGeometry", {
            "x": str(x - 150), "y": str(y - 22), "width": "300", "height": "30", "as": "geometry",
        }))

    ET.indent(root_file, space="  ")
    ET.ElementTree(root_file).write(OUT / "app-er.drawio", encoding="utf-8", xml_declaration=True)


def write_svg() -> None:
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" '
        f'viewBox="0 0 {WIDTH} {HEIGHT}">',
        '<style>text{font-family:"Microsoft YaHei","Noto Sans CJK SC",sans-serif;fill:#183047}'
        '.title{font-size:28px;font-weight:700}.subtitle{font-size:17px;fill:#486174}'
        '.entity-title{font-size:20px;font-weight:700}.field{font-size:17px}'
        '.edge-label{font-size:16px;font-weight:600}</style>',
        f'<rect width="{WIDTH}" height="{HEIGHT}" fill="#f8fbfd"/>',
        '<text x="70" y="55" class="title">校园小卖部最终应用层 ER 补充图</text>',
        '<text x="70" y="97" class="subtitle">与第六周十张核心业务表 ER 图配套；黄色实体由第七至九周应用新增</text>',
    ]
    for relation in RELATIONS:
        points = " ".join(f"{x},{y}" for x, y in relation.points)
        parts.append(f'<polyline points="{points}" fill="none" stroke="#43627a" stroke-width="2.4"/>')
    for entity in ENTITIES:
        color = "#fff2cc" if entity.added_by_app else "#ffffff"
        parts.append(f'<rect x="{entity.x}" y="{entity.y}" width="{BOX_WIDTH}" height="{BOX_HEIGHT}" '
                     f'rx="12" fill="{color}" stroke="#35536b" stroke-width="2"/>')
        parts.append(f'<text x="{entity.x + 16}" y="{entity.y + 36}" class="entity-title">'
                     f'{escape(entity.title)}</text>')
        for index, field in enumerate(entity.fields):
            parts.append(f'<text x="{entity.x + 16}" y="{entity.y + 75 + index * 29}" class="field">'
                         f'{escape(field)}</text>')
    for relation in RELATIONS:
        x, y = relation.label_at
        label = f"{relation.code} {relation.label}"
        parts.append(f'<rect x="{x - 155}" y="{y - 22}" width="310" height="29" '
                     'rx="5" fill="#f8fbfd" opacity="0.97"/>')
        parts.append(f'<text x="{x}" y="{y}" class="edge-label" text-anchor="middle">'
                     f'{escape(label)}</text>')
    parts.extend([
        '<rect x="80" y="790" width="1440" height="95" rx="8" fill="#e9f1f5"/>',
        '<text x="98" y="816" class="subtitle">PK 主码；AK 候选码；FK 外码。联系标签按 source→target / 反向读取。</text>',
        '<text x="98" y="843" class="subtitle">* 顾客账号不关联员工；管理员/店员账号必须关联一名员工。员工可没有应用账号。</text>',
        '<text x="98" y="870" class="subtitle">** 旧销售单可没有归属行；通过应用创建的新销售单由过程写入归属。账号不是会员实体。</text>',
        '</svg>',
    ])
    (OUT / "app-er.svg").write_text("\n".join(parts), encoding="utf-8")


if __name__ == "__main__":
    write_drawio()
    write_svg()
    print("已生成 app-er.drawio 和 app-er.svg")
