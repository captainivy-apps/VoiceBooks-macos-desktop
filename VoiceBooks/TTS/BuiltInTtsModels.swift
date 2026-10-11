import Foundation

/// Built-in sherpa-onnx TTS model catalog (ported from the Kotlin build).
enum BuiltInTtsModels {
    static let baseUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"

    static let models: [TtsModelInfo] = [
        entry("vits-melo-tts-zh_en", "中英双语 MeloTTS", "zh+en", 163000000, 1, "vits", .vits),
        entry("sherpa-onnx-vits-zh-ll", "中文多音色 LL", "zh", 116000000, 5, "vits", .vits),
        entry("vits-zh-hf-theresa", "中文女声 Theresa", "zh", 117770000, 804, "vits", .vits),
        entry("vits-zh-hf-eula", "中文女声 Eula", "zh", 117734000, 804, "vits", .vits),
        entry("vits-zh-hf-fanchen-wnj", "中文男声 WNJ", "zh", 116000000, 1, "vits", .vits),
        entry("vits-piper-zh_CN-huayan-medium", "中文女声 华研", "zh", 65680000, 1, "vits", .vits),
        entry("vits-icefall-zh-aishell3", "中文 AISHELL3 多音色", "zh", 30820000, 174, "vits", .vits),
        entry("vits-piper-en_US-lessac-medium", "English Lessac (男声)", "en", 64000000, 1, "vits", .vits),
        entry("vits-piper-en_US-glados", "English GLaDOS", "en", 65633000, 1, "vits", .vits),
        entry("vits-coqui-en-ljspeech", "English LJSpeech (女声)", "en", 112713000, 1, "vits", .vits),
        entry("vits-coqui-en-vctk", "English VCTK 多音色", "en", 119543000, 109, "vits", .vits),
        entry("vits-piper-en_GB-southern_english_female_medium", "English 英式女声", "en", 78373000, 1, "vits", .vits),
        entry("vits-zh-hf-keqing", "中文女声 Keqing", "zh", 117766000, 804, "vits", .vits),
        entry("vits-zh-hf-bronya", "中文女声 Bronya", "zh", 117769000, 804, "vits", .vits),
        entry("vits-zh-hf-echo", "中文男声 Echo", "zh", 117734000, 804, "vits", .vits),
        entry("vits-zh-hf-zenyatta", "中文男声 Zenyatta", "zh", 117763000, 804, "vits", .vits),
        entry("vits-zh-hf-fanchen-C", "中文男声 C", "zh", 116530000, 1, "vits", .vits),
        entry("vits-zh-hf-fanchen-ZhiHuiLaoZhe", "中文男声 智慧老者", "zh", 116668000, 1, "vits", .vits),
        entry("vits-zh-hf-abyssinvoker", "中文女声 Abyss Invoker", "zh", 117770000, 804, "vits", .vits),
        entry("vits-zh-hf-doom", "中文男声 Doom", "zh", 117770000, 804, "vits", .vits),
        entry("vits-zh-hf-fanchen-ZhiHuiLaoZhe_new", "中文男声 智慧老者（新版）", "zh", 116668000, 1, "vits", .vits),
        entry("vits-zh-hf-fanchen-unity", "中文男声 Unity", "zh", 116530000, 804, "vits", .vits),
        entry("vits-piper-zh_CN-xiao_ya-medium", "中文女声 小雅", "zh", 57700000, 1, "vits", .vits),
        entry("vits-piper-zh_CN-chaowen-medium", "中文男声 超文", "zh", 57600000, 1, "vits", .vits),
        entry("vits-piper-zh_CN-xiao_ya-medium-int8", "中文女声 小雅（轻量）", "zh", 13400000, 1, "vits", .vits),
        entry("vits-piper-zh_CN-chaowen-medium-int8", "中文男声 超文（轻量）", "zh", 13400000, 1, "vits", .vits),
        entry("vits-cantonese-hf-xiaomaiiwn", "粤语女声 小麦", "yue", 105464000, 804, "vits", .vits),
        entry("vits-melo-tts-en", "英文 MeloTTS", "en", 158944000, 1, "vits", .vits),
        entry("vits-piper-en_US-amy-low", "English Amy", "en", 65523000, 1, "vits", .vits),
        entry("vits-piper-en_US-kristin-medium", "English Kristin", "en", 65683000, 1, "vits", .vits),
        entry("vits-piper-en_GB-cori-medium", "English Cori (英式)", "en", 65681000, 1, "vits", .vits),
        entry("vits-piper-en_US-ryan-medium", "English Ryan", "en", 65638000, 1, "vits", .vits),
        entry("vits-piper-en_US-lessac-high", "English Lessac 高品质", "en", 112838000, 1, "vits", .vits),
        entry("vits-piper-en_US-libritts_r-medium", "English LibriTTS 多音色", "en", 80116000, 904, "vits", .vits),
        entry("vits-piper-en_GB-vctk-medium", "English VCTK 英式多音色", "en", 78602000, 109, "vits", .vits),
        entry("vits-coqui-en-ljspeech-neon", "English LJSpeech Neon", "en", 112713000, 1, "vits", .vits),
        entry("vits-coqui-de-css10", "Deutsch CSS10", "de", 65532000, 1, "vits", .vits),
        entry("vits-coqui-fr-css10", "Français CSS10", "fr", 65473000, 1, "vits", .vits),
        entry("vits-coqui-es-css10", "Español CSS10", "es", 65514000, 1, "vits", .vits),
        entry("vits-coqui-pt-cv", "Português", "pt", 65472000, 1, "vits", .vits),
        entry("vits-piper-ru_RU-ruslan-medium", "Русский Ruslan", "ru", 65635000, 1, "vits", .vits),
        entry("vits-piper-ru_RU-irina-medium", "Русский Irina", "ru", 65579000, 1, "vits", .vits),
        entry("vits-mimic3-ko_KO-kss_low", "한국어 KSS", "ko", 65272000, 1, "vits", .vits),
        entry("vits-piper-vi_VN-vais1000-medium", "Tiếng Việt", "vi", 65580000, 1, "vits", .vits),
        entry("vits-mms-tha", "ภาษาไทย MMS", "th", 105238000, 1, "vits", .vits),
        entry("vits-mms-rus", "Русский MMS", "ru", 105236000, 1, "vits", .vits),
        entry("vits-piper-tr_TR-fettah-medium", "Türkçe", "tr", 65600000, 1, "vits", .vits),
        entry("vits-piper-fa-haaniye_low", "فارسی", "fa", 65520000, 1, "vits", .vits),
        entry("vits-coqui-bn-custom_female", "বাংলা (女声)", "bn", 105521000, 1, "vits", .vits),
        entry("kokoro-multi-lang-v1_1", "Kokoro 多语 v1.1", "zh+en", 356266000, 103, "kokoro", .kokoro),
        entry("kokoro-int8-multi-lang-v1_1", "Kokoro 多语 v1.1 (轻量)", "zh+en", 143585000, 103, "kokoro", .kokoro),
        entry("kokoro-en-v0_19", "Kokoro 英文 v0.19", "en", 312134000, 11, "kokoro", .kokoro),
        entry("kokoro-int8-en-v0_19", "Kokoro 英文 v0.19 (轻量)", "en", 100828000, 11, "kokoro", .kokoro),
        entry("kitten-nano-en-v0_1-fp16", "Kitten Nano 英文", "en", 35082000, 8, "kitten", .kitten),
        entry("kitten-mini-en-v0_1-fp16", "Kitten Mini 英文", "en", 65000000, 16, "kitten", .kitten),
    ]

    static let families: [TtsModelFamily] = [.vits, .kokoro, .kitten]

    static func modelsForFamily(_ family: TtsModelFamily) -> [TtsModelInfo] {
        models.filter { $0.family == family }
    }

    static func info(for id: String) -> TtsModelInfo? { models.first { $0.id == id } }

    private static func entry(_ id: String, _ name: String, _ language: String, _ size: Int64,
        _ speakers: Int, _ type: String, _ family: TtsModelFamily) -> TtsModelInfo {
        TtsModelInfo(
            id: id, name: name, language: language, sizeBytes: size,
            downloadUrl: "\(baseUrl)/\(id).tar.bz2",
            modelType: type, family: family, speakerCount: speakers)
    }
}
