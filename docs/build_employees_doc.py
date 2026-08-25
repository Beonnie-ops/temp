"""Собирает Word-документ с описанием HTTP-сервиса employees для внешних интеграторов.

Запуск: python3 docs/build_employees_doc.py
Требуется: pip install python-docx
"""

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.shared import Pt, RGBColor

OUTPUT = "docs/employees-api.docx"


def code(document, text):
    paragraph = document.add_paragraph()
    paragraph.paragraph_format.space_after = Pt(6)
    paragraph.paragraph_format.left_indent = Pt(12)
    run = paragraph.add_run(text)
    run.font.name = "Consolas"
    run.font.size = Pt(9)
    return paragraph


def table(document, headers, rows):
    element = document.add_table(rows=1, cols=len(headers))
    element.style = "Table Grid"
    for cell, title in zip(element.rows[0].cells, headers):
        run = cell.paragraphs[0].add_run(title)
        run.bold = True
        run.font.size = Pt(9)
    for row in rows:
        cells = element.add_row().cells
        for cell, value in zip(cells, row):
            cell.paragraphs[0].add_run(value).font.size = Pt(9)
    document.add_paragraph()
    return element


document = Document()

normal = document.styles["Normal"]
normal.font.name = "Calibri"
normal.font.size = Pt(10.5)

title = document.add_paragraph()
title.alignment = WD_ALIGN_PARAGRAPH.CENTER
run = title.add_run("Сервис получения данных сотрудника (employees)")
run.bold = True
run.font.size = Pt(15)

subtitle = document.add_paragraph()
subtitle.alignment = WD_ALIGN_PARAGRAPH.CENTER
run = subtitle.add_run("Инструкция для внешней интеграции. 1С:ЗУП, публикация Holding_ZUP")
run.font.size = Pt(10)
run.font.color.rgb = RGBColor(0x60, 0x60, 0x60)

document.add_paragraph(
    "Сервис возвращает по ФИО сотрудника его организацию, подразделение, "
    "табельный номер и должность."
)

document.add_heading("1. Запрос", level=1)
code(
    document,
    "GET http://10.12.15.112/Holding_ZUP/hs/employees"
    "?name1=Денис&name2=Шимонов&name3=Викторович",
)
table(
    document,
    ["Параметр", "Часть ФИО", "Пример"],
    [
        ("name1", "Имя", "Денис"),
        ("name2", "Фамилия", "Шимонов"),
        ("name3", "Отчество", "Викторович"),
    ],
)
document.add_paragraph(
    "Внимание: name1 — это имя, фамилия передаётся в name2. Порядок не совпадает "
    "с привычным «Фамилия Имя Отчество»."
)
document.add_paragraph(
    "Значения содержат кириллицу, поэтому при сборке URL в коде их нужно "
    "кодировать в percent-encoding UTF-8 (urlencode / КодироватьСтроку). "
    "Готовые HTTP-клиенты делают это сами."
)

document.add_heading("2. Авторизация", level=1)
document.add_paragraph("Basic-аутентификация, логин и пароль пользователя 1С:")
code(document, "Authorization: Basic <base64(логин:пароль)>")
document.add_paragraph(
    "Без заголовка сервис отвечает 401 Unauthorized с "
    'WWW-Authenticate: Basic realm="1C:Enterprise 8.3". '
    "Логин и пароль запрашиваются у администратора 1С отдельно под каждую систему-потребителя."
)

document.add_heading("3. Ответ", level=1)
document.add_paragraph(
    "JSON-массив. Массив приходит всегда, в том числе для одного сотрудника, — "
    "разбирайте результат как коллекцию."
)
code(
    document,
    "[\n"
    "  {\n"
    '    "organization": "ООО \\"ЛибретикГрупп\\"",\n'
    '    "division": "Отдел информационных технологий",\n'
    '    "number": "0600-00375",\n'
    '    "job": "инженер-программист",\n'
    '    "name1": "Денис",\n'
    '    "name2": "Шимонов",\n'
    '    "name3": "Викторович"\n'
    "  }\n"
    "]",
)
table(
    document,
    ["Поле", "Тип", "Описание"],
    [
        ("organization", "строка", "Организация-работодатель"),
        ("division", "строка", "Подразделение"),
        (
            "number",
            "строка",
            "Табельный номер. Только строка: есть дефис и ведущие нули",
        ),
        ("job", "строка", "Должность"),
        ("name1 / name2 / name3", "строка", "Имя / фамилия / отчество из запроса"),
    ],
)
document.add_paragraph(
    "Сервис отдаёт заголовок Content-Type: text/html, хотя в теле JSON. "
    "Разбирайте тело как JSON не глядя на заголовок: response.json() и "
    "автоматическая десериализация по типу содержимого на таком ответе падают."
)

document.add_heading("4. Коды ответа", level=1)
table(
    document,
    ["Код", "Причина", "Что делать"],
    [
        ("200", "Запрос обработан", "Разобрать JSON"),
        ("401", "Нет заголовка Authorization, неверный пароль", "Проверить учётные данные, повтор не поможет"),
        ("403", "У пользователя нет прав на сервис", "Обратиться к администратору 1С"),
        ("404", "Ошибка в адресе", "Сверить URL с разделом 1"),
        ("500", "Ошибка внутри сервиса", "Сообщить владельцу сервиса время запроса"),
        ("503", "База недоступна или нет лицензий", "Повторить с задержкой"),
    ],
)

document.add_heading("5. Пример вызова", level=1)
code(
    document,
    "curl -u 'логин:пароль' -G \\\n"
    "     'http://10.12.15.112/Holding_ZUP/hs/employees' \\\n"
    "     --data-urlencode 'name1=Денис' \\\n"
    "     --data-urlencode 'name2=Шимонов' \\\n"
    "     --data-urlencode 'name3=Викторович'",
)

document.add_heading("6. Требования к интеграции", level=1)
for item in (
    "Пароль хранить в секрет-хранилище или переменных окружения, не в коде.",
    "Указывать таймаут запроса (рекомендуется 30 секунд) и корректно обрабатывать 503 — "
    "база может быть недоступна во время обновления.",
    "Публикация работает по HTTP без TLS, доступна только из внутренней сети. "
    "Сервис отдаёт персональные данные, передача их за пределы согласованного контура не допускается.",
    "Ограничение на частоту запросов не задано; при массовой обработке ФИО делайте вызовы последовательно.",
):
    document.add_paragraph(item, style="List Bullet")

document.add_heading("7. Уточнить у владельца сервиса", level=1)
for item in (
    "Обязательны ли все три параметра и можно ли искать только по фамилии.",
    "Учитывается ли регистр и работает ли поиск по неполному значению.",
    "Что возвращается, если сотрудник не найден: пустой массив или ошибка.",
    "Попадают ли в ответ уволенные сотрудники и совместители "
    "(может ли на одного человека прийти несколько записей).",
):
    document.add_paragraph(item, style="List Bullet")

document.save(OUTPUT)
print("Сохранено:", OUTPUT)
