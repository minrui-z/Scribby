#!/usr/bin/env python3
"""
proofread.py — 本地 AI 校稿腳本
stdin:  JSON { segments: [{startTimeMs, endTimeMs, text, speakerLabel}], mode, language }
stdout: JSON { segments: [{text}] }  (只有 text，順序與輸入對應)
stderr: 進度 log
"""
import json
import os
import re
import sys

# ────────────────────────────────────────────────
MODEL_ID = "mlx-community/gemma-3-text-4b-it-4bit"
BATCH_SIZE = 5
CONTEXT_BEFORE = 2
CONTEXT_AFTER = 2
MAX_TOKENS = 1024
TEMPERATURE = 0.1

MODE_INSTRUCTIONS = {
    "conservative": (
        "保守校正",
        "【校稿範圍（僅限以下項目，其餘一律保留原文）】\n"
        "- 明顯的 ASR 同音字錯誤（例：「在」→「再」、「的」→「得」「地」）\n"
        "- 段落末尾完全缺少標點時，補上句號（。）或逗號（，）\n\n"
        "【絕對禁止】\n"
        "- 不改變任何語意或語氣\n"
        "- 不增刪詞彙，不重組句子結構\n"
        "- 不消除口語習慣詞（嗯、啊、那個…）\n"
        "- 不「優化」看起來不順的表達——只修能確認是 ASR 錯誤的部分",
    ),
    "standard": (
        "一般校正",
        "【校稿範圍】\n"
        "- ASR 同音字與錯別字（依上下文判斷正確字）\n"
        "- 缺失或明顯錯誤的標點符號（句號、逗號、問號、驚嘆號）\n"
        "- 因 ASR 斷句錯誤導致語意不通的短句，可小幅改寫但須保留原意\n\n"
        "【限制】\n"
        "- 不做大幅重寫或意譯\n"
        "- 保留說話者的口吻與語氣\n"
        "- 人名、專有名詞、縮寫若無法確認錯誤則保留原文\n"
        "- 口語習慣詞（嗯、啊、就是…）除非干擾語意否則保留",
    ),
    "readable": (
        "可讀版整理",
        "【整理目標：將口語轉寫改寫為適合閱讀的文字，同時忠實保留說話者的意思】\n\n"
        "【可執行的操作】\n"
        "- 刪除口語冗詞：「嗯」「啊」「呃」「那個」「就是說」「然後」（句首）「對對對」等\n"
        "- 合併因 ASR 截斷而重複的詞語（例：「然後然後」→「然後」、「就是就是」→「就是」）\n"
        "- 修正錯別字、同音字錯誤與標點\n"
        "- 適度重組句子結構，使語句流暢自然\n\n"
        "【限制】\n"
        "- 保留說話者的個人風格與語氣，不要改成書面文學語體\n"
        "- 不新增原文沒有的資訊，不刪除有意義的內容\n"
        "- 人名、專有名詞保留原文",
    ),
}

SYSTEM_PROMPT = (
    "你是一位專業的語音轉寫校稿助手。\n"
    "你收到的輸入是語音辨識（ASR）自動轉寫的結果，可能包含同音字錯誤、缺少標點、或因麥克風收音中斷而產生的重複詞語。\n"
    "每筆輸入由多個 segment 組成，每個 segment 附有三位數序號（id）與原始文字（text）。\n\n"
    "【語言規則——最高優先】\n"
    "1. 輸出語言必須與輸入語言一致。輸入是英文就輸出英文，輸入是日文就輸出日文，以此類推。\n"
    "2. 唯一例外：若輸入為簡體中文，則輸出改為繁體中文（字形轉換，語意不變）。\n"
    "3. 若同一段 segment 混有多種語言，各語言部分分別適用以上規則。\n\n"
    "【輸出格式規則】\n"
    "4. 輸出必須是合法 JSON，結構為 {\"segments\": [{\"id\": \"...\", \"text\": \"...\"}]}\n"
    "5. 每個 segment 的 id 必須與輸入完全一致，不得增加或減少 segment 數量\n"
    "6. 只修改 text 欄位，不修改 id\n\n"
    "【校稿原則】\n"
    "7. 人名、地名、品牌名、專有名詞若無法確認是 ASR 錯誤，保留原文\n"
    "8. 說話者的語氣、情緒與個人風格須謹慎保留\n"
    "9. 若某段文字語意完整、無明顯錯誤，保留原文即可，不必強行修改"
)


def _log(msg: str) -> None:
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def _log_json(prefix: str, payload: dict) -> None:
    sys.stderr.write(prefix + " " + json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stderr.flush()


def _error(msg: str, code: int = 1) -> None:
    _log(msg)
    sys.exit(code)


# ────────────────────────────────────────────────

def load_model():
    cache_dir = os.environ.get("SCRIBBY_MLX_MODEL_CACHE")
    if cache_dir:
        os.environ["HF_HOME"] = cache_dir

    try:
        from mlx_lm import load, generate  # type: ignore
        from mlx_lm.sample_utils import make_sampler  # type: ignore
        _log(f"正在載入 AI 校稿模型（{MODEL_ID}）…")
        _log("首次使用會自動下載約 2.6 GB，請稍候。")
        model, tokenizer = load(MODEL_ID)
        _log("AI 校稿模型已就緒")
        sampler = make_sampler(temp=TEMPERATURE)
        return model, tokenizer, generate, sampler
    except Exception as e:
        _error(f"載入 AI 校稿模型失敗：{e}", code=2)


_LANGUAGE_NAMES = {
    "zh": "中文",
    "zh-TW": "中文（繁體）",
    "zh-CN": "中文（簡體）",
    "en": "英文",
    "ja": "日文",
    "ko": "韓文",
    "fr": "法文",
    "de": "德文",
    "es": "西班牙文",
    "pt": "葡萄牙文",
    "it": "義大利文",
    "ru": "俄文",
    "ar": "阿拉伯文",
    "th": "泰文",
    "vi": "越南文",
    "id": "印尼文",
    "ms": "馬來文",
}

# 高頻簡體字（這些字在繁體中文中不存在或字形明顯不同）
_SIMPLIFIED_MARKERS = frozenset(
    "们这讨细开运处该协议进间换发标来传给达际队实话难"
    "时获长现两边样义务动态电报关节别际审该问题组织"
    "说话对产业务员课题见识让结负责联统确认则为认"
    "选择办理应学专业临习体验与无论据带着做法项目"
    "图书电话设备维护系统管理支持质量测试数据分析"
    "报告总结经验教训建议计划执行监督评估改善优化"
    "创新研究发展战略目标方向重点关键成功指标绩效"
    "预算资金成本效益投资回报风险管理控制合规监管"
)


def _is_simplified_chinese(segments: list[dict]) -> bool:
    """從 segments 取樣，判斷文字是否以簡體中文為主。"""
    sample = " ".join(seg.get("text", "") for seg in segments[:20])
    hits = sum(1 for ch in sample if ch in _SIMPLIFIED_MARKERS)
    # 超過 1% 的字符命中簡體標記字集，判定為簡體
    total = len([ch for ch in sample if "\u4e00" <= ch <= "\u9fff"])
    if total == 0:
        return False
    return hits / total > 0.01


def build_prompt(all_segs, batch_start: int, batch_end: int, mode: str, language: str = "zh", is_simplified: bool = False) -> str:
    mode_name, mode_instruction = MODE_INSTRUCTIONS[mode]
    ctx_start = max(0, batch_start - CONTEXT_BEFORE)
    ctx_end = min(len(all_segs), batch_end + CONTEXT_AFTER)

    lang_display = _LANGUAGE_NAMES.get(language, language)

    lines: list[str] = []

    if is_simplified:
        lines.append("【語言】輸入語言：中文（簡體）")
        lines.append("【重要】輸入為簡體中文。請在校稿的同時，將所有簡體字轉換為繁體中文輸出。字形轉換，語意與語氣不變。")
    else:
        lines.append(f"【語言】輸入語言：{lang_display}")

    if ctx_start < batch_start:
        lines.append("\n【上下文參考，不需校稿】")
        for i in range(ctx_start, batch_start):
            lines.append(f"[{i:03d}] {all_segs[i]['text']}")

    lines.append("\n【本次校稿目標】")
    for i in range(batch_start, batch_end):
        lines.append(f"[{i:03d}] {all_segs[i]['text']}")

    if batch_end < ctx_end:
        lines.append("\n【下文參考，不需校稿】")
        for i in range(batch_end, ctx_end):
            lines.append(f"[{i:03d}] {all_segs[i]['text']}")

    target_ids = [f"{i:03d}" for i in range(batch_start, batch_end)]
    lines.append(
        f"\n請依「{mode_name}」模式校稿目標 segment（{target_ids[0]}–{target_ids[-1]}）。\n"
        f"{mode_instruction}\n\n"
        f'輸出 JSON（只包含目標 segments）：'
        f'{{"segments": [{{"id": "{target_ids[0]}", "text": "…"}}, …]}}'
    )
    return "\n".join(lines)


def parse_response(response_text: str, batch_segs: list[dict], batch_start: int) -> list[dict]:
    """解析模型回傳，失敗時 fallback 到原始文字。"""
    _log(f"[DEBUG] 模型原始輸出（前 400 字）：{response_text[:400]}")

    # 嘗試直接解析
    try:
        data = json.loads(response_text)
        _log("[DEBUG] 解析成功：直接 JSON")
        return data["segments"]
    except Exception:
        pass

    # 嘗試從 markdown code block 提取
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", response_text, re.DOTALL)
    if m:
        try:
            data = json.loads(m.group(1))
            _log("[DEBUG] 解析成功：markdown code block")
            return data["segments"]
        except Exception:
            pass

    # 嘗試找最外層 { }
    m = re.search(r"\{.*\}", response_text, re.DOTALL)
    if m:
        try:
            data = json.loads(m.group(0))
            _log("[DEBUG] 解析成功：regex { }")
            return data["segments"]
        except Exception:
            pass

    _log(f"警告：無法解析 AI 回傳，使用原始文字（前 200 字）：{response_text[:200]}")
    return [{"id": f"{batch_start + j:03d}", "text": seg["text"]} for j, seg in enumerate(batch_segs)]


def proofread_batch(model, tokenizer, generate_fn, sampler, all_segs, batch_start, batch_end, mode, language: str = "zh", is_simplified: bool = False) -> list[str]:
    """回傳本批次校稿後的 text 清單，順序對應 batch_start..batch_end。"""
    batch_segs = all_segs[batch_start:batch_end]
    prompt = build_prompt(all_segs, batch_start, batch_end, mode, language, is_simplified)

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": prompt},
    ]

    try:
        formatted = tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
        )
    except Exception:
        # 部分 tokenizer 不支援 system role，合併到 user
        combined = SYSTEM_PROMPT + "\n\n" + prompt
        messages = [{"role": "user", "content": combined}]
        formatted = tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
        )

    response = generate_fn(
        model,
        tokenizer,
        prompt=formatted,
        max_tokens=MAX_TOKENS,
        sampler=sampler,
        verbose=False,
    )

    corrected = parse_response(response, batch_segs, batch_start)

    # 對齊長度：如果模型少回一些，用原始文字補
    result_texts: list[str] = []
    corrected_map = {item.get("id", f"{batch_start + j:03d}"): item["text"] for j, item in enumerate(corrected)}
    for j in range(len(batch_segs)):
        seg_id = f"{batch_start + j:03d}"
        result_texts.append(corrected_map.get(seg_id, batch_segs[j]["text"]))

    return result_texts


# ────────────────────────────────────────────────

def main() -> None:
    if "--warmup" in sys.argv[1:]:
        load_model()
        return

    raw = sys.stdin.read()
    if not raw.strip():
        _error("stdin 為空", code=1)

    try:
        payload = json.loads(raw)
    except Exception as e:
        _error(f"JSON 解析失敗：{e}", code=1)

    segments: list[dict] = payload.get("segments", [])
    mode: str = payload.get("mode", "standard")
    language: str = payload.get("language", "zh")

    if mode not in MODE_INSTRUCTIONS:
        _error(f"不支援的校稿模式：{mode}", code=1)

    if not segments:
        # 沒有 segments，直接回傳空結果
        sys.stdout.write(json.dumps({"segments": []}, ensure_ascii=False) + "\n")
        sys.stdout.flush()
        return

    model, tokenizer, generate_fn, sampler = load_model()

    # 語言偵測：language code 明確指定簡體，或文字內容含大量簡體字
    simplified_by_code = language in ("zh-CN", "zh_CN", "zhs", "zh-Hans")
    simplified_by_text = _is_simplified_chinese(segments)
    is_simplified = simplified_by_code or simplified_by_text
    if is_simplified:
        _log("偵測到簡體中文，校稿輸出將轉為繁體中文")

    results: list[dict] = list(segments)  # 複製，保留原始結構
    total = len(segments)
    total_batches = max((total + BATCH_SIZE - 1) // BATCH_SIZE, 1)
    i = 0
    while i < total:
        batch_end = min(i + BATCH_SIZE, total)
        batch_number = i // BATCH_SIZE + 1
        _log(f"PROOFREAD_PROGRESS current={batch_number} total={total_batches} phase=start")
        corrected_texts = proofread_batch(model, tokenizer, generate_fn, sampler, segments, i, batch_end, mode, language, is_simplified)
        for j, text in enumerate(corrected_texts):
            results[i + j] = {"text": text}
        _log_json(
            "PROOFREAD_TEXT",
            {
                "current": batch_number,
                "total": total_batches,
                "text": "\n".join(t for t in corrected_texts if t.strip()),
            },
        )
        _log(f"PROOFREAD_PROGRESS current={batch_number} total={total_batches} phase=done")
        _log(f"校稿進度：{batch_end}/{total} 段")
        i = batch_end

    _log(f"PROOFREAD_PROGRESS current={total_batches} total={total_batches} phase=finished")

    sys.stdout.write(json.dumps({"segments": results}, ensure_ascii=False) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
