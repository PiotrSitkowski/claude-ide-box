"""Checksum validators. Valid examples are the public specimen numbers used
in the specifications or their Wikipedia articles; none belongs to a person."""

import unittest

from pii_airgap import validators as v


class ValidatorTests(unittest.TestCase):
    def check(self, fn, good, bad):
        for s in good:
            self.assertTrue(fn(s), "%s should accept %r" % (fn.__name__, s))
        for s in bad:
            self.assertFalse(fn(s), "%s should reject %r" % (fn.__name__, s))

    def test_iban(self):
        self.check(
            v.iban_valid,
            ["GB82 WEST 1234 5698 7654 32", "DE89370400440532013000",
             "PL61 1090 1014 0000 0712 1981 2874", "pl61109010140000071219812874"],
            ["GB82 WEST 1234 5698 7654 33", "DE8937040044053201300",
             "PL61 1090 1014 0000 0712 1981 287", "XX00", "PL6110901014000007121981287X"],
        )

    def test_payment_card(self):
        self.check(
            v.card_valid,
            ["4111 1111 1111 1111", "5555-5555-5555-4444", "378282246310005", "6011111111111117"],
            ["4111 1111 1111 1112", "1234567812345670", "0000000000000000", "41111111"],
        )

    def test_pesel(self):
        self.check(
            v.pesel_valid,
            ["44051401359", "02270803624"],
            ["44051401358", "44053201352", "4405140135", "00000000000"],
        )

    def test_nip(self):
        self.check(v.nip_valid, ["1234563218", "123-456-32-18", "PL1234563218"],
                   ["1234563217", "0000000000", "123456321"])

    def test_regon(self):
        self.check(v.regon_valid, ["123456785", "12345678512347"],
                   ["123456786", "12345678512348", "12345678"])

    def test_pl_id_card(self):
        self.check(v.pl_idcard_valid, ["ABA300000", "aba 300000"], ["ABA400000", "AB3000000", "ABA30000"])

    def test_pl_passport(self):
        self.check(v.pl_passport_valid, ["EA1234567"], ["EA2234567", "E11234567", "EA123456"])

    def test_us_ssn(self):
        self.check(v.us_ssn_valid, ["123-45-6789", "123 45 6789"],
                   ["000-45-6789", "666-45-6789", "900-45-6789", "123-00-6789", "123-45-0000"])

    def test_de_tax_id(self):
        self.check(v.de_taxid_valid, ["86095742719"], ["86095742718", "06095742719", "8609574271"])

    def test_es_dni_nie(self):
        self.check(v.es_dni_valid, ["12345678Z", "12345678-Z", "X1234567L"], ["12345678A", "X1234567A"])

    def test_it_codice_fiscale(self):
        self.check(v.it_cf_valid, ["RSSMRA85T10A562S"], ["RSSMRA85T10A562T", "RSSMRA85T10A562"])

    def test_fr_nir(self):
        self.check(v.fr_nir_valid, ["2 55 08 14 168 025 38", "255081416802538"], ["255081416802539"])

    def test_nl_bsn(self):
        self.check(v.nl_bsn_valid, ["111222333"], ["111222334", "000000000"])

    def test_se_personnummer(self):
        self.check(v.se_pnr_valid, ["811228-9874", "19811228-9874"], ["811228-9875", "811328-9874"])

    def test_fi_hetu(self):
        self.check(v.fi_hetu_valid, ["131052-308T"], ["131052-308U", "131352-308T"])

    def test_be_national_number(self):
        self.check(v.be_nrn_valid, ["85.07.30-033.28", "85073003328"], ["85.07.30-033.29"])


if __name__ == "__main__":
    unittest.main()
