from collections import Counter
from datetime import datetime
from pathlib import Path

from openpyxl import Workbook, load_workbook
from openpyxl.chart import BarChart, Reference
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

TABS = {
    "metrics": "Метрики",
    "cohort_info": "Когорта",
    "exclusions": "Отбор",
    "categories": "Категории",
    "prices": "Цены",
    "intersections": "Пересечения",
    "event_distribution": "События",
    "coverage": "Покрытие UTC",
    "data_passport": "Паспорт",
}
TITLES = {
    "purchase_7d": "Покупка того же товара за 7 дней",
    "purchase_24h": "Покупка того же товара за 24 часа",
    "purchase_7d_including_t0": "Покупка за 7 дней, включая секунду добавления",
    "purchase_equal_t0": "Покупка в секунду добавления",
    "purchase_same_session": "Покупка в той же сессии",
    "purchase_other_session": "Покупка в другой сессии",
    "purchase_unknown_event_session": "Покупка с неизвестной сессией покупки¹",
    "purchase_other_product": "Покупка другого товара",
    "remove_same_product": "Удаление добавленного товара",
    "purchase_unknown_start_session": "Покупка при неизвестной сессии добавления",
}
INK = "162236"
SOFT = "E8F0F5"
TEAL = "077C7F"
WHITE = "FFFFFF"
MUTED = "48596E"
PERCENT = "0.00%"
INTEGER = "#,##0"


def add_table(book, key, header, rows):
    sheet = book.create_sheet(TABS[key])
    sheet.append(header)
    for row in rows:
        sheet.append(row)
    sheet.freeze_panes = "B2"
    sheet.auto_filter.ref = sheet.dimensions
    sheet.sheet_view.showGridLines = False
    sheet.row_dimensions[1].height = 28

    for column, name in enumerate(header, 1):
        sheet.column_dimensions[get_column_letter(column)].width = max(15, min(76, len(name) + 5))
        for cell in sheet.iter_cols(min_col=column, max_col=column):
            for entry in cell:
                if entry.row == 1:
                    entry.fill = PatternFill("solid", fgColor=INK)
                    entry.font = Font(color=WHITE, bold=True)
                    continue
                if name == "rate" or name.startswith("rate_"):
                    entry.number_format = PERCENT
                elif isinstance(entry.value, int):
                    entry.number_format = INTEGER
                elif isinstance(entry.value, datetime):
                    entry.number_format = "yyyy-mm-dd hh:mm:ss"
                if entry.row % 2 == 0:
                    entry.fill = PatternFill("solid", fgColor=SOFT)

    if key == "data_passport":
        for column, name in enumerate(header, 1):
            if name in {"publisher_archive", "sha256"}:
                sheet.column_dimensions[get_column_letter(column)].width = 76
    if key == "metrics":
        sheet.column_dimensions["A"].width = 32
    if key == "intersections":
        sheet.column_dimensions["A"].width = 34
        sheet.column_dimensions["B"].width = 34


def heading(sheet, row, label, fill):
    sheet.merge_cells(start_row=row, end_row=row, start_column=1, end_column=4)
    cell = sheet.cell(row, 1, label)
    cell.font = Font(color=WHITE, bold=True, size=17 if row == 1 else 11)
    cell.fill = PatternFill("solid", fgColor=fill)
    cell.alignment = Alignment(vertical="center")
    sheet.row_dimensions[row].height = 38 if row == 1 else 23


def build(path: Path, tables):
    book = Workbook()
    overview = book.active
    overview.title = "Дашборд"
    book.properties.title = "REES46 | Косметика после добавления в корзину"
    book.properties.description = "Агрегаты октябрьской когорты с семидневным окном UTC."
    book.properties.creator = "REES46 Cart Case"
    overview.sheet_view.showGridLines = False
    overview.freeze_panes = "B8"
    for letter, width in {"A": 67, "B": 17, "C": 17, "D": 16}.items():
        overview.column_dimensions[letter].width = width

    heading(overview, 1, "Покупка косметики после добавления в корзину", INK)
    cohort_header, cohort_rows = tables["cohort_info"]
    cohort = dict(zip(cohort_header, cohort_rows[0]))
    period = f"{cohort['first_t0_utc']:%d.%m.%Y} — {cohort['last_t0_utc']:%d.%m.%Y} UTC"
    notes = {
        3: f"Когорта первых подходящих добавлений · {period}",
        4: "Единица — покупатель × товар. У каждой пары есть полные семь дней наблюдения.",
        5: "Покупки ищем в журнале магазина. Итог за пределами журнала неизвестен.",
        19: "¹ Среди пар с известной сессией добавления.",
        20: "Флаги могут пересекаться. Карта пересечений приведена на отдельном листе.",
        31: "Единица цены соответствует исходному полю price. Деньги за получение товара в журнале отсутствуют.",
    }
    for row, note in notes.items():
        overview.merge_cells(start_row=row, end_row=row, start_column=1, end_column=4)
        cell = overview.cell(row, 1, note)
        cell.font = Font(color=MUTED, size=10)
    heading(overview, 6, "Покупки и действия после добавления", TEAL)
    for column, label in enumerate(("Показатель", "Числитель", "Знаменатель", "Доля"), 1):
        cell = overview.cell(7, column, label)
        cell.font = Font(color=INK, bold=True)
        cell.fill = PatternFill("solid", fgColor=SOFT)
    for row, (metric, count, denominator, rate) in enumerate(tables["metrics"][1], 8):
        for column, value in enumerate((TITLES[metric], count, denominator, rate), 1):
            cell = overview.cell(row, column, value)
            cell.font = Font(color=TEAL if row == 8 else INK, bold=row == 8)
            cell.alignment = Alignment(vertical="center")
            if column >= 2:
                cell.number_format = PERCENT if column == 4 else INTEGER
            if row % 2 == 0:
                cell.fill = PatternFill("solid", fgColor=SOFT)
    heading(overview, 22, "Окна 24 часа и 7 дней по цене на момент добавления", TEAL)
    price_header, prices = tables["prices"]
    for column, value in enumerate(("Сегмент", "Пар", "24 часа", "7 дней"), 1):
        cell = overview.cell(23, column, value)
        cell.font = Font(color=INK, bold=True)
        cell.fill = PatternFill("solid", fgColor=SOFT)
    for row, record in enumerate(prices, 24):
        segment, pairs, _, _, rate_24h, rate_7d = record
        for column, value in enumerate((segment, pairs, rate_24h, rate_7d), 1):
            cell = overview.cell(row, column, value)
            if column >= 2:
                cell.number_format = INTEGER if column == 2 else PERCENT

    chart = BarChart()
    chart.type = "col"
    chart.style = 10
    chart.title = "Конверсия по ценовым диапазонам"
    chart.y_axis.title = "Доля пар"
    chart.y_axis.numFmt = PERCENT
    chart.y_axis.scaling.min = 0
    chart.width = 24
    chart.height = 9
    chart.add_data(Reference(overview, min_col=3, max_col=4, min_row=23, max_row=28), titles_from_data=True)
    chart.set_categories(Reference(overview, min_col=1, min_row=24, max_row=28))
    chart.series[0].graphicalProperties.solidFill = "9ABFCE"
    chart.series[1].graphicalProperties.solidFill = TEAL
    overview.add_chart(chart, "A33")

    for name, (header, rows) in tables.items():
        add_table(book, name, header, rows)
    path.parent.mkdir(parents=True, exist_ok=True)
    book.save(path)
    check_workbook(path, tables)


def check_workbook(path, tables):
    with path.open("rb") as stream:
        book = load_workbook(stream, read_only=True, data_only=True)
        overview = book["Дашборд"]
        for row, (metric, count, denominator, rate) in enumerate(tables["metrics"][1], 8):
            reference = (TITLES[metric], count, denominator, rate)
            actual = tuple(overview.cell(row, column).value for column in range(1, 5))
            assert actual[:3] == reference[:3]
            if rate is None:
                assert actual[3] is None
            else:
                assert abs(actual[3] - rate) < 1e-12
        dimensions = Counter(sheet.title for sheet in book.worksheets[1:])
        assert dimensions == Counter(TABS.values())
        for name, (header, rows) in tables.items():
            sheet = book[TABS[name]]
            assert len(rows) + 1 == sheet.max_row
            assert len(header) == sheet.max_column
        book.close()
