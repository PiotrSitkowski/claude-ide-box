# What the Windows installer offers on its "What to install?" screen.
# Names and descriptions are in i18n\*.psd1 (Module_<Id>, Module_<Id>_Desc);
# the domains a programming language opens are read from proxy/presets/<Preset>.txt.
# SizeMB: growth over the base image on disk (`docker image ls`), measured 2026-11-09 on top of claude-ide-box/base; 0 = not measured, no size shown.
@{
  # base image (1.46 GB) + proxy (0.22 GB), as `docker image ls` shows them
  BaseSizeMB = 1680

  # Office sizes as measured in the usual chain docs -> libreoffice -> ocr (they share
  # fonts and poppler; alone: docs 420, libreoffice 590, ocr 130).
  Office = @(
    @{ Id = 'docs'; SizeMB = 420 }
    @{ Id = 'libreoffice'; SizeMB = 500 }
    @{ Id = 'ocr'; SizeMB = 60; PerLanguageMB = 7 }
  )

  # Personal data: pii-airgap (https://github.com/PiotrSitkowski/pii-airgap), a
  # separate image with its own language models (1.36 GB, measured 2026-11-09).
  # Fetched with git at exactly this commit and built inside WSL; a newer
  # version comes with a new Claude IDE Box release that changes this line.
  Pii = @{
    Id = 'pii'
    SizeMB = 1360
    Repo = 'https://github.com/PiotrSitkowski/pii-airgap'
    Commit = '5ffdc57e2a08313801f1bb83af54c4174a649f20'
    # PII_SCAN_MIN_CONFIDENCE for office work and both (the scan before a
    # project's first session); programming keeps Claude IDE Box's default.
    ScanMinConfidenceOffice = '0.7'
  }

  Dev = @(
    @{ Id = 'python'; Preset = 'python'; SizeMB = 50 }
    @{ Id = 'php'; Preset = 'php'; SizeMB = 190 }
    @{ Id = 'go'; Preset = 'go'; SizeMB = 360 }
    @{ Id = 'rust'; Preset = 'rust'; SizeMB = 900 }
    @{ Id = 'java'; Preset = 'java'; SizeMB = 490 }
  )

  # Tesseract code -> culture whose native name is shown (each person finds
  # their language written in that language).
  OcrLanguages = @(
    @{ Code = 'eng'; Culture = 'en' }
    @{ Code = 'deu'; Culture = 'de' }
    @{ Code = 'fra'; Culture = 'fr' }
    @{ Code = 'spa'; Culture = 'es' }
    @{ Code = 'ita'; Culture = 'it' }
    @{ Code = 'por'; Culture = 'pt' }
    @{ Code = 'nld'; Culture = 'nl' }
    @{ Code = 'pol'; Culture = 'pl' }
    @{ Code = 'ces'; Culture = 'cs' }
    @{ Code = 'slk'; Culture = 'sk' }
    @{ Code = 'hun'; Culture = 'hu' }
    @{ Code = 'ron'; Culture = 'ro' }
    @{ Code = 'bul'; Culture = 'bg' }
    @{ Code = 'hrv'; Culture = 'hr' }
    @{ Code = 'slv'; Culture = 'sl' }
    @{ Code = 'srp'; Culture = 'sr' }
    @{ Code = 'ukr'; Culture = 'uk' }
    @{ Code = 'rus'; Culture = 'ru' }
    @{ Code = 'lit'; Culture = 'lt' }
    @{ Code = 'lav'; Culture = 'lv' }
    @{ Code = 'est'; Culture = 'et' }
    @{ Code = 'fin'; Culture = 'fi' }
    @{ Code = 'swe'; Culture = 'sv' }
    @{ Code = 'dan'; Culture = 'da' }
    @{ Code = 'nor'; Culture = 'nb' }
    @{ Code = 'ell'; Culture = 'el' }
    @{ Code = 'tur'; Culture = 'tr' }
    @{ Code = 'ara'; Culture = 'ar' }
    @{ Code = 'heb'; Culture = 'he' }
    @{ Code = 'hin'; Culture = 'hi' }
    @{ Code = 'vie'; Culture = 'vi' }
    @{ Code = 'tha'; Culture = 'th' }
    @{ Code = 'ind'; Culture = 'id' }
    @{ Code = 'jpn'; Culture = 'ja' }
    @{ Code = 'kor'; Culture = 'ko' }
    @{ Code = 'chi_sim'; Culture = 'zh-Hans' }
    @{ Code = 'chi_tra'; Culture = 'zh-Hant' }
  )
}
