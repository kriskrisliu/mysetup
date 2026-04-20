---
name: tensorrt-fp16
description: Implement or debug a PyTorch-to-TensorRT FP16 inference path with ONNX, NVIDIA ModelOpt, TensorRT engine building, RuntimeRegistry execution, and SSIM/PSNR validation. Use this skill whenever the user asks to add TRT FP16 acceleration, convert a PyTorch model to TensorRT FP16, rebuild/validate a TensorRT engine, investigate TensorRT FP16 accuracy drops, or compare PyTorch/ONNX/TensorRT outputs.
---

# TensorRT FP16 conversion and validation

Use this skill to add or repair a TensorRT FP16 backend for an existing PyTorch inference script while preserving the original data loading, preprocessing, postprocessing, saving, and metrics.

## Core principles

- TensorRT should replace only the model forward/backend call. Do not rewrite unrelated pipeline logic.
- Keep a PyTorch baseline and a direct ONNX Runtime check when debugging accuracy.
- Cache artifacts under a project-local `dummy/` or equivalent scratch directory unless the project says otherwise.
- Engine artifacts are tied to model/checkpoint, input shape, batch size, TensorRT/CUDA version, GPU architecture, and precision. Include shape/precision in filenames.
- Always validate both latency and task metric quality, not just successful engine construction.

## Recommended flow

```text
PyTorch checkpoint/model
  -> PyTorch FP32 ONNX via torch.onnx.export
  -> FP16 ONNX via NVIDIA ModelOpt convert_to_f16
  -> TensorRT FP16 engine via ModelOpt build_engine(..., output_dir=project_local_dir)
  -> RuntimeRegistry TRT client inference
  -> compare against GT or PyTorch baseline with task metrics
```

If direct `.half()` export is known to work for the model, it is also valid:

```text
PyTorch model.cuda().half().eval()
  -> fixed-shape FP16 ONNX
  -> TensorRT FP16 engine
  -> TRT backend inference
```

However, for transformer/attention models, direct `.half()` export can fail if masks/constants remain FP32 while activations become FP16. In that case, prefer FP32 ONNX export followed by ModelOpt ONNX FP16 conversion.

## Artifact naming

Use a project-local artifact directory, for example:

```text
dummy/trt_artifacts/<model_or_config>/
  bs1_patch512_torch.onnx
  bs1_patch512_fp16.onnx
  bs1_patch512_fp16.modelopt.engine
  bs1_patch512_fp16.engine
  bs1_patch512_fp16.timing.cache
  modelopt_tmp/
```

Suggested fields in filenames:

- backend batch size
- patch/input size
- precision (`fp16`)
- optional model/checkpoint/config suffix

## Export ONNX

For a fixed-shape model:

```python
export_shape = (backend_batch_size, channels, height, width)
dummy_input = torch.zeros(export_shape, dtype=torch.float32, device="cuda")
export_model = WrappedModel(model).cuda().eval()

torch.onnx.export(
    export_model,
    dummy_input,
    torch_onnx_path,
    input_names=["input"],
    output_names=["output"],
    opset_version=17,
    do_constant_folding=True,
)
```

Then convert to FP16 with ModelOpt:

```python
import onnx
from modelopt.onnx.autocast.convert import convert_to_f16

model = onnx.load(torch_onnx_path, load_external_data=True)
model_fp16 = convert_to_f16(model, keep_io_types=True)
onnx.save(model_fp16, fp16_onnx_path)
```

Note: ModelOpt may upgrade the ONNX opset internally, often to opset 21. If ONNX Runtime CUDA fails on `Squeeze(21)` during a direct ONNX quality test, create the ORT session with graph optimization disabled.

```python
import onnxruntime as ort

session_options = ort.SessionOptions()
session_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
session = ort.InferenceSession(
    fp16_onnx_path,
    sess_options=session_options,
    providers=["CUDAExecutionProvider", "CPUExecutionProvider"],
)
```

## Build TensorRT FP16 engine with ModelOpt

Prefer direct `build_engine(...)` when you need to control the artifact output directory. Some ModelOpt `RuntimeClient.ir_to_compiled()` versions do not pass `output_dir`, and may write to `/tmp/modelopt_build`, which can fail with permission errors on shared machines.

```python
from modelopt.torch._deploy._runtime import RuntimeRegistry
from modelopt.torch._deploy._runtime.tensorrt.engine_builder import build_engine
from modelopt.torch._deploy.utils.torch_onnx import OnnxBytes

client = RuntimeRegistry.get({"runtime": "TRT", "accelerator": "GPU", "precision": "fp16"})
onnx_bytes_obj = OnnxBytes(fp16_onnx_path)
compiled_model, trtexec_log = build_engine(
    onnx_bytes_obj,
    trt_mode="fp16",
    engine_path=engine_path + ".tmp",
    timing_cache_path=timing_cache_path,
    output_dir=modelopt_tmp_dir,
)
if not compiled_model:
    raise RuntimeError(trtexec_log.decode(errors="replace"))

with open(modelopt_engine_path, "wb") as f:
    f.write(compiled_model)

# ModelOpt prepends a 32-byte hash to the raw TensorRT engine bytes.
with open(raw_engine_path, "wb") as f:
    f.write(compiled_model[32:])
```

## RuntimeRegistry backend pattern

Wrap PyTorch/ONNX/TensorRT backends behind a shared method such as `infer(...)` or `run(...)`.

```python
class ModelOptTRTBackend:
    def __init__(self, client, compiled_model, backend_batch_size, input_size):
        self.client = client
        self.compiled_model = compiled_model
        self.backend_batch_size = backend_batch_size
        self.input_size = input_size
        self.io_shapes = {
            "input": [backend_batch_size, 13, input_size, input_size],
        }

    def infer(self, inp_patch):
        padded_batch, original_batch_size, original_h, original_w = prepare_backend_batch(
            inp_patch, self.backend_batch_size, self.input_size
        )
        real = padded_batch.cuda(non_blocking=True).half()
        with torch.inference_mode():
            outputs = self.client.inference(self.compiled_model, [real], io_shapes=self.io_shapes)
        if len(outputs) != 1:
            raise RuntimeError(f"Unexpected TensorRT output count: {len(outputs)}")
        pred = outputs[0].detach().float().cpu()
        return crop_backend_prediction(pred, original_batch_size, original_h, original_w)
```

If using raw TensorRT Python + CuPy instead, use TensorRT's input dtype for input buffers and output dtype for output buffers; do not assume both are the same.

## Wrapper CLI pattern

Expose parameters similar to:

```bash
bash ./bash_test.sh <gpu> <test_num> <use_fp16> <backend> <trt_force_rebuild>
```

Example commands:

```bash
# Reuse cached artifacts
bash ./bash_test.sh 0 10 0 trt_fp16

# Force rebuild ONNX, FP16 ONNX, TensorRT engine, then validate metrics
bash ./bash_test.sh 0 1 0 trt_fp16 1

# Test FP16 ONNX directly to determine whether accuracy is already bad before TensorRT
bash ./bash_test.sh 0 1 0 onnx_fp16 1
```

Use an idle GPU and follow project-specific GPU constraints.

## Debug checklist for bad TRT FP16 accuracy

1. Confirm PyTorch FP32 or PyTorch FP16 baseline metric.
2. Export FP32 ONNX and convert to FP16 ONNX.
3. Run FP16 ONNX directly with ONNX Runtime CUDA and measure metrics.
4. If FP16 ONNX metric is good but TRT metric is bad, focus on engine build/runtime.
5. Prefer ModelOpt `build_engine(..., output_dir=...)` + RuntimeRegistry inference over a hand-written raw TensorRT runner when accuracy differs.
6. Check padding/cropping for fixed batch engines: crop output back to original batch/height/width.
7. Ensure input dtype/layout/normalization exactly match the PyTorch path.
8. Record latency over a warm-up plus `test_num` measured runs.

## Common failures and fixes

- `PermissionError: /tmp/modelopt_build/...`: call `build_engine(..., output_dir=<project-local-dir>)` directly instead of relying on `client.ir_to_compiled(...)`.
- Direct `.half()` export fails with `expected scalar type Float but found Half`: attention masks/constants may remain FP32; export FP32 ONNX then use ModelOpt ONNX FP16 conversion.
- ONNX Runtime CUDA fails on `Squeeze(21)`: disable ORT graph optimizations for the ONNX-only diagnostic path.
- TensorRT engine builds but SSIM drops: run the FP16 ONNX directly. If ONNX is good, switch engine build/runtime path or compare TRT runtime outputs on identical inputs.

## Documentation to update

After validation, update project docs with:

- exact run commands for cached run, forced rebuild, and ONNX-only diagnostic
- artifact directory and file names
- latency, SSIM, PSNR or relevant task metrics
- whether the quality target is met
- known remaining blockers, especially INT8 if it is still below threshold
