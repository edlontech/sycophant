# Changelog

## [0.4.0](https://github.com/edlontech/sycophant/compare/sycophant-v0.3.0...sycophant-v0.4.0) (2026-04-17)


### ⚠ BREAKING CHANGES

* Rename reasoning param to reasoning_effort

### Features

* Add auto_execute_tools option to disable tool auto-execution ([053ee00](https://github.com/edlontech/sycophant/commit/053ee000fb6fee2da67f22af09b8fda303cfe316))
* Add configurable strict mode for tools ([88ef880](https://github.com/edlontech/sycophant/commit/88ef880a0f20280da450abbabbf2873c91704eb6))
* Add support to accumulator in the streams ([19a331c](https://github.com/edlontech/sycophant/commit/19a331c47ed453ed21e3704dbf300a14f02898ee))
* Added reasoning_budget to the shared params ([e568a59](https://github.com/edlontech/sycophant/commit/e568a598b6722502482d9e1736f07aafaa7ce8a8))
* Map timeout errors to Provider.Timeout and add configurable timeout ([a7b9130](https://github.com/edlontech/sycophant/commit/a7b913059d65c51c29d6704e314391ece4ff30fd))
* Refactor the reasoning processing ([3053590](https://github.com/edlontech/sycophant/commit/3053590e0e6e5e01f405f10de616e58ccc141115))


### Bug Fixes

* Added failed states to streams ([7c57f6a](https://github.com/edlontech/sycophant/commit/7c57f6a30d20d7143920af719521e4b569ae3211))
* Fixes the issue when joining multiple system messages ([78ec197](https://github.com/edlontech/sycophant/commit/78ec197b5c1476abb6c9e3748d4b3a71fff319ee))
* Include error and payload in ResponseValidator JSON parse failure ([a011c8e](https://github.com/edlontech/sycophant/commit/a011c8ebe3bc65ee5f3cace8f3925b369133b779))
* Include parameter path in validation error messages ([0f34d07](https://github.com/edlontech/sycophant/commit/0f34d07b095b3fbb7a7bb24510ab08886584953c))
* normalize tool return values before wire encoding ([6bb8687](https://github.com/edlontech/sycophant/commit/6bb8687af849f881e82020798b7a2c3ae1122a49))
* Propagate reasoning id for OpenAI Responses thinking ([17c42c6](https://github.com/edlontech/sycophant/commit/17c42c6b41b45c503fcacf9b732414fa689544d1))
* Reasoning budget can be 0 ([e482eb8](https://github.com/edlontech/sycophant/commit/e482eb8fa99bc8e4623161bb74c35572d89aca1d))


### Code Refactoring

* Rename reasoning param to reasoning_effort ([1354a30](https://github.com/edlontech/sycophant/commit/1354a3055437d9df3eba401d3e321db72decd354))

## [0.3.0](https://github.com/edlontech/sycophant/compare/sycophant-v0.2.0...sycophant-v0.3.0) (2026-04-14)

### Features

* tools and structured output ([c801277](https://github.com/edlontech/sycophant/commit/c80127780fa48d42ecc5d117bdfdf59c9da4282c))

### Continuous Integration

* Fix release-please version on README ([c435c8f](https://github.com/edlontech/sycophant/commit/c435c8f0949319613d2d58b044e483fe6fe9d5ce))

## [0.2.0](https://github.com/edlontech/sycophant/compare/v0.1.0...v0.2.0) (2026-04-10)

### Features

* replace legacy cost map with LLMDB component-based pricing ([032f978](https://github.com/edlontech/sycophant/commit/032f9789fee223c9e2c473a11b0b02ef5f7c7650))
* unify wire and embedding protocol registries ([fefc7ec](https://github.com/edlontech/sycophant/commit/fefc7ecb29e0872941642976b8c382acd104f902))

## 0.1.0 (2026-03-13)


### Features

* add agent mode with GenStateMachine-based conversational agent ([fd89593](https://github.com/edlontech/sycophant/commit/fd895937c0de836266a38842298ce4397ef44f42))
* Add automatic cost calculation to Usage struct ([2c75c58](https://github.com/edlontech/sycophant/commit/2c75c5862d447ffc6bf1fb444d686f27cf724906))
* Add cost fields to telemetry usage metadata ([1106921](https://github.com/edlontech/sycophant/commit/11069217258c9f71c1ed3976004addfbb8cb30aa))
* Add finish_reason field with canonical atom mappings across all wire protocols ([fa4f770](https://github.com/edlontech/sycophant/commit/fa4f7703942083ecbb4638eca6b79a7b54d6a102))
* add Inspect protocol for all Sycophant structs ([2128bdc](https://github.com/edlontech/sycophant/commit/2128bdc66a3e30c86e3a0e44460cf6347a8fdc44))
* add local provider support via LLMDB auth flag ([7c14775](https://github.com/edlontech/sycophant/commit/7c14775693e7b9387d8b838a641af34d3d87c396))
* Add optional OpenTelemetry integration with GenAI semantic conventions ([ee8d951](https://github.com/edlontech/sycophant/commit/ee8d95124ffa3d835d247ce865efc8e7b05a7c18))
* AWS Bedrock Converse API integration ([bfc298d](https://github.com/edlontech/sycophant/commit/bfc298df4250028d002041884499cef5e8037d74))
* Azure AI Foundry provider support ([a8c6318](https://github.com/edlontech/sycophant/commit/a8c6318e97a987fe7b7d4fa0be30a32adc7acc8b))
* credentials, transport & pipeline ([258d363](https://github.com/edlontech/sycophant/commit/258d363d99801cfa61d74cf8b02ff260b7b2a7d9))
* Embedding API with Bedrock Cohere Embed v4 support ([692155a](https://github.com/edlontech/sycophant/commit/692155ac4bad74aac34eeed6c364957a86243363))
* Extensible registry for auth and wire protocols ([5620038](https://github.com/edlontech/sycophant/commit/5620038ce059a90209674dcb1215af11064473e7))
* JSON-serializable structs for conversation persistence ([ab6cb7d](https://github.com/edlontech/sycophant/commit/ab6cb7d399524ef5efa32ff43ea1ebd0a8257f8e))
* model-first public API with Context as first-class conversation handle ([774acd3](https://github.com/edlontech/sycophant/commit/774acd37b346500a9b076f855fd79e7c6be67d7f))
* multi-provider wire protocol adapters and recording infrastructure ([2ff0c27](https://github.com/edlontech/sycophant/commit/2ff0c27f99f11a960c6314004defe1b0ad641fa9))
* multi-turn conversation support ([5ba57a4](https://github.com/edlontech/sycophant/commit/5ba57a4afe1498f1425d4c9a602552270dd973aa))
* Project Base ([b4755f6](https://github.com/edlontech/sycophant/commit/b4755f6bc86a55ad7500097dbab8fc9a800456c9))
* SSE streaming support with recording test infrastructure ([1519171](https://github.com/edlontech/sycophant/commit/151917135648753632b5f822de0d0a52d1f5f944))
* tools and structured output ([c801277](https://github.com/edlontech/sycophant/commit/c80127780fa48d42ecc5d117bdfdf59c9da4282c))
* wire protocol adapters for OpenAI Completions and Responses APIs ([f8c4e85](https://github.com/edlontech/sycophant/commit/f8c4e85562735dd79bfc2d1bd4ec1d5443034a59))
* Wire-specific parameter validation and provider improvements ([324d2c7](https://github.com/edlontech/sycophant/commit/324d2c7ecd446aea31ea7332513908b9e7b99e9b))


### Bug Fixes

* Fixed dialyzer ([02f35c4](https://github.com/edlontech/sycophant/commit/02f35c4adc472dac4ec3d51ec8101040ce732cbb))
* Fixed OpenTelemetry module to require only if otel is available ([4dcfd7a](https://github.com/edlontech/sycophant/commit/4dcfd7a68b70dc659b7412cbc8bcba7d30a06dc2))
* Fixed ordering of middlewares ([0188bbb](https://github.com/edlontech/sycophant/commit/0188bbbb764a131f360033117fad22fd3a6ace4b))
* Fixes replay tests ([b66c5dd](https://github.com/edlontech/sycophant/commit/b66c5dddedcfbd63d079f5864af5246371e95d49))
* Improved params mapping ([2e95a40](https://github.com/edlontech/sycophant/commit/2e95a400541f063ed8713525026dd8570f532a6f))
* Moved Allow-List to code ([243f191](https://github.com/edlontech/sycophant/commit/243f19180352784eb5a22fae9bd716132824c54b))
* Only allowing providers we support ([821656c](https://github.com/edlontech/sycophant/commit/821656cab13b7fad2ad05ae664b961c8baefc0a9))
* Replace Application.put_env with Mimic stubs in tests ([bb653a9](https://github.com/edlontech/sycophant/commit/bb653a93c998d03486f868fe132b66bed3b2a416))


### Continuous Integration

* Add Release-Please ([ae32e71](https://github.com/edlontech/sycophant/commit/ae32e719a3e9a30253918805cf3772587988011d))
