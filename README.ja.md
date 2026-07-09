# ocaml-ai-agent — OCaml で書いた、ケイパビリティで縛る LLM エージェント用ツール群

> **これは Anil Madhavapeddy 氏の [`ocaml-deepseek`](https://tangled.org/anil.recoil.org/ocaml-deepseek) から派生しています。**
> エージェントループ、ケイパビリティで縛るツール層（`Tool` / `Toolbox`）、
> 型付きの引数コーデック、会話モデルはいずれも本家に強く倣っています。
> 本リポジトリはそれを **クラウド専用** に切り詰めた再実装で、DeepSeek
> エンジンも GGUF の重みもネイティブコードも含みません。ローカルモデルの
> 代わりに、Eio + piaf 経由で Anthropic Claude API を駆動します。
> 非公式です。本家の作者と提携・承認の関係はありません。ライセンスは本家同様 ISC。

🇬🇧 English version: [README.md](./README.md)

[Anthropic Claude Messages API](https://docs.anthropic.com/en/api/messages)
専用の、小さなクラウド専用ツール利用エージェントです。OCaml で
[Eio](https://github.com/ocaml-multicore/eio) と
[piaf](https://github.com/anmonteiro/piaf) の上に実装しています。

このプロジェクトの肝は **ツール** です。すべてのツールは Eio のケイパビリティで
縛られており、モデルが要求したものではなく、呼び出し側が手渡したものにしか
到達できません。`read` ツールはディレクトリハンドルを 1 つだけ保持し、その
サブツリーの外には出られません。`dns` はネットワークを、`bash` はプロセス
マネージャを保持します。ツールの引数は型付きの `Schema` コンビネータで
記述され、これがモデルに提示する JSON Schema とデコーダの両方を生成するため、
ハンドラは型付きの OCaml 値を受け取ります。

## ビルド

```sh
dune build
```

純粋な OCaml です。システム依存は（piaf の TLS 経由で）OpenSSL のみ。
モデルの重みも C ツールチェインも不要です。

## 使い方

API キーを設定します（`x-api-key` ヘッダにのみ送られ、ログには残りません）:

```sh
export ANTHROPIC_API_KEY=sk-ant-...
```

```sh
# 一発のチャット（トークン単位でストリーミング）:
dune exec bin/main.exe -- chat "モナドを一文で説明して。"

# モデルを指定（デフォルト: claude-opus-4-8）:
dune exec bin/main.exe -- chat -m claude-opus-4-8 "こんにちは？"

# ツール利用エージェント。ワークスペースに閉じ込め、1 プロンプトで終了:
dune exec bin/main.exe -- agent -d ./workspace -p "README.md を読んで要約して"

# 対話的なエージェント（Ctrl-D で終了）:
dune exec bin/main.exe -- agent -d ./workspace

# ストリーミングを無効化（1 ターンにつき 1 レスポンス）:
dune exec bin/main.exe -- chat --no-stream "こんにちは"
```

エージェントは `read` / `write` / `dns` / `bash` を提示します。それぞれ
`--dir` のワークスペース（ファイルシステム系ツール）か、付与された
ケイパビリティに閉じ込められています。

## アーキテクチャ

- `Schema` — 型付き引数コンビネータ。1 つの記述から JSON Schema とデコーダを
  生成します。
- `Tool` / `Toolbox` — `Schema` から組み立てる、ケイパビリティで縛られたツール。
- `Message` — プロバイダ非依存の会話表現（ツールコールの id を保持）。
- `Llm.S` — バックエンドの抽象（`converse`）。OpenAI/Gemini を足すならここ。
- `Anthropic` — piaf 上の Claude バックエンド（非ストリーミング + SSE、tool_use）。
- `Agent` — バックエンドを駆動し、ツールを実行し、結果を会話に折り込みます。

## クレジット・ライセンス

Anil Madhavapeddy 氏の
[`ocaml-deepseek`](https://tangled.org/anil.recoil.org/ocaml-deepseek) から派生しており、
コードのほとんどはそこから来ています。元になった同梱の DeepSeek-V4 (DS4)
推論エンジン（本リポジトリには含みません）は
[antirez](https://github.com/antirez/ds4) 氏によるものです。ライセンスは本家同様 ISC。
