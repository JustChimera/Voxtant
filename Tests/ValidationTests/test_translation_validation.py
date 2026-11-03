from pathlib import Path
import json
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import translation_validation as tv


class TranslationConstraintTests(unittest.TestCase):
    def case(self,key):
        return next(c for c in json.loads(tv.SPEC.read_text())['cases'] if c['id']==key)

    def passes(self,key,text):
        return all(c['passed'] for c in tv.checks(self.case(key),{'text':text}))

    def test_negation_cannot_be_hidden_by_fluent_russian(self):
        self.assertTrue(self.passes('negation','Не используйте зубы.'))
        self.assertFalse(self.passes('negation','Используйте зубы.'))

    def test_chinese_order_and_repetitions_are_exact(self):
        self.assertTrue(self.passes('mixed-repetitions','Скажите 你好, 你好, 你好.'))
        self.assertFalse(self.passes('mixed-repetitions','Скажите 你好, 你好.'))
        self.assertFalse(self.passes('mixed-order','Сначала скажите 再见, затем 你好.'))

    def test_context_is_not_allowed_to_leak_into_current_translation(self):
        self.assertTrue(self.passes('no-extra-context','Спасибо.'))
        self.assertFalse(self.passes('no-extra-context','Спасибо за университет и банк.'))

    def test_placeholder_and_wrong_language_are_rejected(self):
        self.assertFalse(self.passes('mixed-word','Слово __ZH_01234567_0__ означает банк.'))
        self.assertFalse(self.passes('mixed-word','The word 银行 means bank.'))
        self.assertTrue(self.passes('mixed-word','Слово 银行 означает банк.'))

    def test_han_preservation_is_not_applied_to_translate_chinese_mode(self):
        self.assertTrue(self.passes('chinese-translate','Я не иду в школу, я иду в банк.'))
        self.assertFalse(self.passes('chinese-translate','我不去学校，我去银行。'))

    def test_number_words_and_digits_are_valid_but_inversion_is_not(self):
        self.assertTrue(self.passes('numbers','Используйте 25 образцов, а не 52.'))
        self.assertTrue(self.passes('numbers','Используйте двадцать пять образцов, а не пятьдесят два.'))
        self.assertFalse(self.passes('numbers','Используйте 52 образца, а не 25.'))


if __name__=='__main__':unittest.main()
