"""Generate the labelled evaluation corpus (eval/corpus.jsonl).

Everything is synthetic: names are random combinations of common first names
and surnames, identifiers are random numbers with valid check digits,
companies are invented. Deterministic (fixed seed), so the corpus and the
scores in the README can be reproduced.

    python3 eval/make_corpus.py > eval/corpus.jsonl
"""

import json
import random
import re
import sys

R = random.Random(20261105)

FIRST = {
    "pl": ["Anna", "Katarzyna", "Małgorzata", "Agnieszka", "Piotr", "Krzysztof", "Tomasz", "Paweł", "Michał", "Ewa",
           "Zofia", "Jakub", "Łukasz", "Joanna", "Marek"],
    "en": ["James", "Mary", "Robert", "Patricia", "John", "Jennifer", "Michael", "Linda", "David", "Elizabeth",
           "Sarah", "Daniel", "Emily", "Thomas", "Laura"],
    "de": ["Lukas", "Anna", "Leon", "Mia", "Jonas", "Lena", "Felix", "Hannah", "Maximilian", "Sophie", "Paul",
           "Katharina", "Stefan", "Jürgen", "Ursula"],
}
LAST = {
    "pl": ["Nowak", "Wiśniewska", "Wójcik", "Kamińska", "Lewandowski", "Zielińska", "Szymański", "Woźniak",
           "Dąbrowski", "Kozłowska", "Jankowski", "Mazur", "Krawczyk", "Piotrowska", "Grabowski"],
    "en": ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis", "Wilson", "Anderson",
           "Taylor", "Moore", "Jackson", "Martin", "Thompson"],
    "de": ["Müller", "Schmidt", "Schneider", "Fischer", "Weber", "Meyer", "Wagner", "Becker", "Schulz", "Hoffmann",
           "Schäfer", "Koch", "Bauer", "Richter", "Klein"],
}
ORGS = {
    "pl": ["Wiślańska Logistyka sp. z o.o.", "Bursztynowe Okna S.A.", "Kowalczyk i Synowie sp.j.", "Mazowiecki Dom Mediowy",
           "Fundacja Zielony Brzeg", "Przychodnia Pod Lipami"],
    "en": ["Bluefield Analytics Ltd", "Harbor & Pine LLP", "Northgate Medical Group", "Crescent Valley Bank",
           "Ashford Robotics Inc.", "Silver Fern Consulting"],
    "de": ["Nordwind Handels GmbH", "Bergmann & Söhne KG", "Rheintal Versicherung AG", "Praxis am Stadtpark",
           "Lindenhof Logistik GmbH", "Alpenblick Software GmbH"],
}
CITIES = {"pl": ["Warszawa", "Kraków", "Gdańsk", "Poznań", "Wrocław", "Lublin", "Rzeszów"],
          "en": ["London", "Manchester", "Boston", "Denver", "Leeds", "Chicago", "Bristol"],
          "de": ["Berlin", "Hamburg", "München", "Köln", "Leipzig", "Dresden", "Bremen"]}
STREETS = {"pl": ["ul. Długa", "ul. Polna", "ul. Leśna", "al. Jana Pawła II", "ul. Słoneczna", "ul. Kwiatowa"],
           "en": ["Baker Street", "Maple Avenue", "Church Road", "Oak Lane", "Station Road", "Elm Drive"],
           "de": ["Hauptstraße", "Gartenweg", "Lindenallee", "Schillerstraße", "Bahnhofstraße", "Rosengasse"]}
MONTHS_PL = ["stycznia", "lutego", "marca", "kwietnia", "maja", "czerwca", "lipca", "sierpnia", "września",
             "października", "listopada", "grudnia"]
MONTHS_EN = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
             "November", "December"]
MONTHS_DE = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober",
             "November", "Dezember"]


def digits(n):
    return "".join(R.choice("0123456789") for _ in range(n))


def pesel():
    while True:
        y, m, d = R.randint(1940, 2005), R.randint(1, 12), R.randint(1, 28)
        mm = m + (20 if y >= 2000 else 0)
        s = "%02d%02d%02d%s" % (y % 100, mm, d, digits(4))
        c = (10 - sum(int(a) * b for a, b in zip(s, [1, 3, 7, 9, 1, 3, 7, 9, 1, 3])) % 10) % 10
        return s + str(c)


def bad_pesel():
    s = pesel()
    return s[:10] + str((int(s[10]) + 1) % 10)


def nip():
    while True:
        s = str(R.randint(1, 9)) + digits(8)
        c = sum(int(a) * b for a, b in zip(s, [6, 5, 7, 2, 3, 4, 5, 6, 7])) % 11
        if c != 10:
            s += str(c)
            return "%s-%s-%s-%s" % (s[:3], s[3:6], s[6:8], s[8:]) if R.random() < 0.6 else s


def regon():
    s = str(R.randint(1, 9)) + digits(7)
    return s + str(sum(int(a) * b for a, b in zip(s, [8, 9, 2, 3, 4, 5, 6, 7])) % 11 % 10)


def iban(cc):
    bban = {"PL": lambda: digits(24), "DE": lambda: digits(18),
            "GB": lambda: "".join(R.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(4)) + digits(14)}[cc]()
    num = "".join(str(int(ch, 36)) for ch in bban + cc + "00")
    s = cc + "%02d" % (98 - int(num) % 97) + bban
    return " ".join(s[i:i + 4] for i in range(0, len(s), 4))


def card():
    s = "4" + digits(14)
    total = 0
    for i, ch in enumerate(reversed(s)):
        d = int(ch)
        if i % 2 == 0:
            d *= 2
            d -= 9 if d > 9 else 0
        total += d
    s += str((10 - total % 10) % 10)
    return " ".join(s[i:i + 4] for i in range(0, 16, 4))


def ssn():
    return "%03d-%02d-%04d" % (R.choice([x for x in range(1, 900) if x != 666]), R.randint(1, 99), R.randint(1, 9999))


def de_taxid():
    while True:
        s = str(R.randint(1, 9)) + digits(9)
        product = 10
        for ch in s:
            t = (int(ch) + product) % 10 or 10
            product = (t * 2) % 11
        return s + str((11 - product) % 10)


def idcard():
    letters = [R.choice("ABCDEFGHIJKLMNOPRSTUWXYZ") for _ in range(3)]
    rest = digits(5)
    vals = [ord(c) - 55 for c in letters] + [int(c) for c in rest]
    w = [7, 3, 1, 7, 3, 1, 7, 3]
    return "".join(letters) + str(sum(a * b for a, b in zip(vals, w)) % 10) + rest


def phone(lang):
    if lang == "pl":
        return R.choice(["+48 %s %s %s" % (R.choice(["501", "601", "698", "512"]), digits(3), digits(3)),
                         "+48%s%s" % (R.choice(["501", "601"]), digits(6))])
    if lang == "de":
        return "+49 %s %s" % (R.choice(["30", "40", "89", "221"]), digits(7))
    return "+1 (%s) 555-%s" % (R.choice(["212", "303", "617"]), "01" + digits(2))


def local_phone():
    return "%s %s %s" % (R.choice(["501", "601", "698"]), digits(3), digits(3))


def dob(lang):
    y, m, d = R.randint(1940, 2004), R.randint(1, 12), R.randint(1, 28)
    style = R.random()
    if lang == "pl":
        return "%02d.%02d.%d" % (d, m, y) if style < 0.6 else "%d %s %d" % (d, MONTHS_PL[m - 1], y)
    if lang == "de":
        return "%02d.%02d.%d" % (d, m, y) if style < 0.6 else "%d. %s %d" % (d, MONTHS_DE[m - 1], y)
    return "%s %d, %d" % (MONTHS_EN[m - 1], d, y) if style < 0.5 else "%d %s %d" % (d, MONTHS_EN[m - 1], y)


def other_date():
    return "%02d.%02d.%d" % (R.randint(1, 28), R.randint(1, 12), R.randint(2019, 2026))


def person(lang):
    return "%s %s" % (R.choice(FIRST[lang]), R.choice(LAST[lang]))


def email_for(name, lang):
    tld = {"pl": "pl", "de": "de", "en": "com"}[lang]
    local = name.lower().replace(" ", ".")
    for a, b in (("ł", "l"), ("ą", "a"), ("ę", "e"), ("ś", "s"), ("ć", "c"), ("ń", "n"), ("ó", "o"), ("ź", "z"),
                 ("ż", "z"), ("ü", "ue"), ("ö", "oe"), ("ä", "ae"), ("ß", "ss")):
        local = local.replace(a, b)
    return "%s@example.%s" % (local, tld)


def street(lang):
    s = R.choice(STREETS[lang])
    n = "%d%s" % (R.randint(1, 180), R.choice(["", "", "/%d" % R.randint(1, 40)]) if lang == "pl" else "")
    return "%s %s" % (s, n) if lang != "en" else "%d %s" % (R.randint(1, 400), s)


def postcode_city(lang):
    return "%s-%s %s" % (digits(2), digits(3), R.choice(CITIES["pl"]))


# Templates: {TYPE} is a labelled slot, {_name} an unlabelled distractor.
TEMPLATES = {
    "pl": [
        "Umowa najmu zawarta w dniu {_date} pomiędzy {PERSON}, PESEL {PESEL}, zamieszkałym przy {ADDRESS}, {ADDRESS2}, a {ORG}.",
        "Zgłoszenie serwisowe nr {_order}: klient {PERSON} (tel. {PHONE}, e-mail {EMAIL}) prosi o kontakt.",
        "Dane do przelewu: {ORG}, NIP {NIP}, rachunek {IBAN}. Faktura {_invoice} na kwotę {_amount} zł.",
        "Pacjentka {PERSON}, ur. {DOB}, zgłosiła się do {ORG} w {LOCATION}.",
        "Pracownik: {PERSON}\nDowód osobisty: {IDCARD}\nTelefon: {LPHONE}\nKonto: {IBAN}",
        "W załączeniu przesyłam protokół ze spotkania w {LOCATION}. Uczestnicy: {PERSON}, {PERSON2}.",
        "REGON {REGON}; spółka {ORG}; reprezentowana przez {PERSON}.",
        "Numer zamówienia {_order} został zrealizowany {_date}. Kod produktu {_sku}, ilość 12.",
        "Płatność kartą {CARD} odrzucona. Prosimy o kontakt: {EMAIL}.",
        "Kierownik projektu {PERSON} przeniósł się z {LOCATION} do {LOCATION2}.",
        "Wersja 2.14.3 wydana {_date}; poprawka błędu #44051 w module rozliczeń.",
        "Proszę o przesłanie dokumentów na adres {ADDRESS}, {ADDRESS2}.",
        # Hard cases, written without tuning the rules to them.
        "Mieszkam na [[ADDRESS:Długiej 5 m. 3]] w [[LOCATION:Krakowie]], mój numer to [[PHONE:601-234-567]], urodziłam się [[DOB:3 maja 1985]] roku.",
        "Wczoraj dzwonił [[PERSON:pan Wójcik]] z [[ORG:Bursztynowych Okien]]; prosił, by oddzwonić do [[PERSON:Zosi Mazur]].",
        "pesel klientki: [[PESEL:7406280717 6]] (literówka w systemie), konto [[IBAN:pl61109010140000071219812874]]",
    ],
    "en": [
        "This agreement is made on {_date} between {PERSON}, residing at {ADDRESS}, {LOCATION}, and {ORG}.",
        "Support ticket {_order}: customer {PERSON} (phone {PHONE}, email {EMAIL}) requested a callback.",
        "Payroll record - employee {PERSON}, SSN {SSN}, date of birth: {DOB}.",
        "Wire the deposit to {ORG}, account {IBAN}, reference {_invoice}.",
        "Patient {PERSON}, born {DOB}, was referred to {ORG} in {LOCATION}.",
        "Meeting notes ({LOCATION}): attendees {PERSON}, {PERSON2}; next review on {_date}.",
        "The card ending in {CARD} was declined; please email {EMAIL}.",
        "Order {_order} shipped on {_date}; SKU {_sku}, 12 units, total ${_amount}.",
        "Release 2.14.3 fixes issue #44051 in the billing module.",
        "{PERSON} moved from {LOCATION} to {LOCATION2} to lead the {ORG} office.",
        "Please send the signed copy to {ADDRESS}, {LOCATION}.",
        "Contact {PERSON} at {PHONE} before {_date}.",
        "Reach me on [[PHONE:07700 900123]] or at [[ADDRESS:12 Hill Rise]], [[LOCATION:Leeds]] [[ADDRESS:LS1 4AP]].",
        "Dr. [[PERSON:O'Neill]] saw [[PERSON:Mrs. J. Smith-Taylor]] (DOB [[DOB:1979-03-02]]) at [[ORG:St Mary's]].",
        "SSN on file: [[SSN:123456789]]; card [[CARD:4111111111111111]].",
    ],
    "de": [
        "Mietvertrag vom {_date} zwischen {PERSON}, wohnhaft {ADDRESS}, {LOCATION}, und der {ORG}.",
        "Serviceanfrage {_order}: Kunde {PERSON} (Telefon {PHONE}, E-Mail {EMAIL}) bittet um Rückruf.",
        "Personalakte: {PERSON}, geboren am {DOB}, Steuer-ID {TAXID}.",
        "Bitte überweisen Sie den Betrag an {ORG}, IBAN {IBAN}, Verwendungszweck {_invoice}.",
        "Die Patientin {PERSON}, geb. {DOB}, wurde an die {ORG} in {LOCATION} überwiesen.",
        "Protokoll der Besprechung in {LOCATION}. Teilnehmer: {PERSON}, {PERSON2}.",
        "Die Kreditkarte {CARD} wurde abgelehnt; Rückfragen an {EMAIL}.",
        "Bestellung {_order} wurde am {_date} versandt; Artikel {_sku}, 12 Stück, {_amount} EUR.",
        "Version 2.14.3 behebt Fehler #44051 im Abrechnungsmodul.",
        "{PERSON} ist von {LOCATION} nach {LOCATION2} gezogen und leitet dort die {ORG}.",
        "Bitte senden Sie die Unterlagen an {ADDRESS}, {LOCATION}.",
        "Rufen Sie {PERSON} unter {PHONE} vor dem {_date} an.",
        "Frau Dr. [[PERSON:Weber]] wohnt [[ADDRESS:Am Mühlbach 7]], [[ADDRESS:80331 München]], Tel. [[PHONE:089 1234567]].",
        "Herr [[PERSON:von der Heide]] arbeitet bei der [[ORG:Sparkasse Nordwest]] in [[LOCATION:Osnabrück]].",
        "Steuer-Identifikationsnummer [[TAXID:86 095 742 719]], IBAN [[IBAN:DE89370400440532013000]].",
    ],
}


def fill(lang, tpl):
    name = person(lang)
    values = {
        "PERSON": name, "PERSON2": person(lang), "ORG": R.choice(ORGS[lang]),
        "LOCATION": R.choice(CITIES[lang]), "LOCATION2": R.choice(CITIES[lang]),
        "ADDRESS": street(lang), "ADDRESS2": postcode_city(lang),
        "DOB": dob(lang), "PESEL": pesel(), "NIP": nip(), "REGON": regon(),
        "IBAN": iban({"pl": "PL", "de": "DE", "en": "GB"}[lang]), "CARD": card(), "SSN": ssn(),
        "TAXID": de_taxid(), "IDCARD": idcard(), "EMAIL": email_for(name, lang),
        "PHONE": phone(lang), "LPHONE": local_phone(),
        "_date": other_date(), "_order": bad_pesel(), "_invoice": "FV/%s/%s" % (R.randint(2020, 2026), digits(4)),
        "_amount": "%d,%02d" % (R.randint(100, 99999), R.randint(0, 99)), "_sku": "SKU-%s-%s" % (digits(4), "AB"),
    }
    if values["LOCATION2"] == values["LOCATION"]:
        values["LOCATION2"] = [c for c in CITIES[lang] if c != values["LOCATION"]][0]
    text, ents, pos = "", [], 0
    for m in re.finditer(r"\{(\w+)\}|\[\[([A-Z]+):(.*?)\]\]", tpl):
        text += tpl[pos:m.start()]
        if m.group(2):
            ents.append({"start": len(text), "end": len(text) + len(m.group(3)), "type": m.group(2)})
            text += m.group(3)
            pos = m.end()
            continue
        key = m.group(1)
        val = values[key]
        if not key.startswith("_"):
            t = re.sub(r"\d", "", key)
            t = {"LPHONE": "PHONE"}.get(t, t)
            ents.append({"start": len(text), "end": len(text) + len(val), "type": t})
        text += val
        pos = m.end()
    text += tpl[pos:]
    return text, ents


def main():
    n = 0
    for lang in ("pl", "en", "de"):
        for rep in range(6):
            for i, tpl in enumerate(TEMPLATES[lang]):
                if "{" not in tpl and rep > 0:
                    continue  # literal hard cases count once
                text, ents = fill(lang, tpl)
                n += 1
                sys.stdout.write(json.dumps({"id": "%s-%02d-%d" % (lang, i, rep), "lang": lang, "text": text,
                                             "entities": ents}, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
