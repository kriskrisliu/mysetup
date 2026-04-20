---
name: tensorrt-int8
description: Use when converting a PyTorch model or inference script to TensorRT INT8, adding ModelOpt PTQ/QDQ ONNX export, calibration data preparation, TensorRT engine caching, and INT8 inference validation.
---

# TensorRT INT8 conversion skill

Use this skill when the user asks to add, design, debug, or review a TensorRT INT8 path for a PyTorch model. The target is usually an existing inference script that already has a working PyTorch FP32/FP16 path.

## Core rule

Only replace the model forward path. Do not rewrite data loading, preprocessing, postprocessing, metrics, or output saving unless the user explicitly asks. Keeping the pipeline unchanged makes INT8 accuracy and speed regressions attributable to quantization or TensorRT rather than unrelated code changes.

## Expected implementation flow

Follow this order:

1. Find the existing PyTorch inference entry point and verify the baseline path.
2. Identify model construction, checkpoint loading, input tensor shape, dtype, device, batch size, and output shape.
3. Add a backend abstraction such as `backend.run(...)` so the main loop can switch between PyTorch and TensorRT with minimal edits.
4. Prepare calibration batches from the real inference preprocessing path, not random tensors.
5. Quantize a copied model with NVIDIA ModelOpt PTQ.
6. Export an INT8 Q/DQ ONNX model.
7. Validate the ONNX with both `onnx.checker.check_model(...)` and an explicit `QuantizeLinear` / `DequantizeLinear` node check.
8. Build or load a TensorRT INT8 engine.
9. Cache calibration data, ONNX, engine, compiled engine blob, and timing cache under a generated artifact prefix.
10. Run a sanity check comparing PyTorch baseline output and TensorRT INT8 output on the same sample input.
11. Reuse the existing full inference loop and report task-specific metrics such as SSIM, PSNR, accuracy, mAP, or output diffs.

## Backend pattern

Use a thin backend wrapper:

```python
class TRTBackend:
    def __init__(self, client, compiled_model, io_shapes):
        self.client = client
        self.compiled_model = compiled_model
        self.io_shapes = io_shapes
        self.name = "trt_int8"

    def run(self, *inputs):
        with torch.inference_mode():
            outputs = self.client.inference(self.compiled_model, list(inputs), io_shapes=self.io_shapes)
        return outputs
```

For a single-output model, returning `outputs[0][: inputs[0].shape[0]]` is useful when the engine has a fixed batch size and the final batch is padded. For multi-output models, explicitly validate output count and shapes.

## Calibration data rules

Calibration data quality determines INT8 quality.

Requirements:

- Use real samples after the same preprocessing used by inference: resize, normalization, padding, channel order, dtype, and shape.
- Do not use random tensors for calibration unless the real production input distribution is random.
- Start with 32, 64, or 128 samples, then increase only if metrics require it.
- Cover representative modes of the data distribution: classes, brightness, length, resolution, scenes, or domains.
- If the engine uses fixed batch size, pad the last calibration batch by repeating the last sample.
- For multi-input models, each calibration item should preserve structure, such as `(image_batch, metadata_batch)`.

Example single-input calibration loop:

```python
def calibrate_loop(current_model):
    for batch in calibration_batches:
        current_model(batch)
```

Example multi-input calibration loop:

```python
def calibrate_loop(current_model):
    for batch in calibration_batches:
        current_model(*batch)
```

## ModelOpt PTQ and Q/DQ ONNX export

Prefer this pattern:

```python
import copy
import modelopt.torch.quantization as mtq
from modelopt.torch._deploy.utils.torch_onnx import OnnxBytes, get_onnx_bytes_and_metadata


class QuantExportWrapper(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, *inputs):
        return self.model(*inputs)


quant_model = QuantExportWrapper(copy.deepcopy(model).eval())
mtq.quantize(quant_model, mtq.INT8_DEFAULT_CFG, forward_loop=calibrate_loop)

sample_input = calibration_batches[0]
onnx_bytes, metadata = get_onnx_bytes_and_metadata(
    quant_model,
    sample_input,
    model_name=model_name,
    remove_exported_model=True,
    onnx_opset=17,
)
OnnxBytes.from_bytes(onnx_bytes).write_to_disk(onnx_dir)
```

Important details:

- Deep-copy the model before quantization so the PyTorch baseline remains unchanged.
- Keep wrapper logic minimal.
- Use the same sample input structure as the model forward expects.
- `mtq.INT8_DEFAULT_CFG` is the first choice; only customize quantization if validation metrics fail.
- Export Q/DQ ONNX. TensorRT should consume `QuantizeLinear` / `DequantizeLinear` nodes.

## ONNX validation

Always validate both graph correctness and INT8 Q/DQ presence:

```python
def validate_qdq_onnx(onnx_path):
    onnx_model = onnx.load(onnx_path)
    onnx.checker.check_model(onnx_model)
    op_types = {node.op_type for node in onnx_model.graph.node}
    if "QuantizeLinear" not in op_types or "DequantizeLinear" not in op_types:
        raise ValueError(f"Exported ONNX is missing Q/DQ nodes: {onnx_path}")
    return onnx_model
```

Also print input shapes, output shapes, node count, and preferably op type counts when debugging.

## TensorRT engine build pattern

Use ModelOpt RuntimeRegistry when available:

```python
from modelopt.torch._deploy._runtime import RuntimeRegistry
from modelopt.torch._deploy.utils.torch_onnx import OnnxBytes

client = RuntimeRegistry.get({"runtime": "TRT", "accelerator": "GPU", "precision": "int8"})
onnx_bytes = OnnxBytes(onnx_path).to_bytes()
compiled_model = client.ir_to_compiled(
    onnx_bytes,
    {"engine_path": engine_path, "timing_cache_path": timing_cache_path},
)
```

If saving both the ModelOpt compiled blob and raw TensorRT engine, this convention may apply in existing code:

```python
TRT_HASH_BYTES = 32
with open(compiled_model_path, "wb") as f:
    f.write(compiled_model)
with open(engine_path, "wb") as f:
    f.write(compiled_model[TRT_HASH_BYTES:])
```

If not using ModelOpt runtime, use `trtexec` against the Q/DQ ONNX:

```bash
trtexec \
  --onnx=model_int8_qdq.onnx \
  --saveEngine=model_int8.engine \
  --int8 \
  --timingCacheFile=model_int8.timing.cache \
  --skipInference
```

For dynamic shapes, include complete optimization profiles:

```bash
trtexec \
  --onnx=model_int8_qdq.onnx \
  --saveEngine=model_int8.engine \
  --int8 \
  --minShapes=x:1x8x256x256 \
  --optShapes=x:4x8x256x256 \
  --maxShapes=x:4x8x256x256 \
  --timingCacheFile=model_int8.timing.cache \
  --skipInference
```

## Caching rules

Artifact names should include every factor that affects compatibility:

- checkpoint or model version
- input resolution, patch size, sequence length, or other shape parameters
- batch size
- precision, e.g. `int8_qdq`
- calibration dataset identity or hash when practical
- opset, TensorRT version, ModelOpt version, or dynamic-shape profile when practical

Typical files:

```text
<int8_cache>/<model_name>/
  calibration_<calib_dataset>.pt
  <checkpoint>_<shape>_bs<batch>_int8_qdq.onnx
  <checkpoint>_<shape>_bs<batch>_int8_qdq.modelopt.engine
  <checkpoint>_<shape>_bs<batch>_int8_qdq.engine
  <checkpoint>_<shape>_bs<batch>_int8_qdq.timing.cache
```

Provide explicit rebuild flags when editing an inference CLI:

```python
parser.add_argument("--calib_data_path", type=str, default=None)
parser.add_argument("--calib_num_samples", type=int, default=64)
parser.add_argument("--rebuild_int8_onnx", action="store_true")
parser.add_argument("--rebuild_int8_engine", action="store_true")
```

Use checkpoint mtime and rebuild flags to decide stale status. If calibration data, quantization config, TensorRT version, or ModelOpt version changes, rebuild the ONNX and engine.

## Sanity check and validation

After building the engine, compare PyTorch baseline and TensorRT INT8 on the same sample:

```python
with torch.inference_mode():
    torch_output = model(sample_input)
    trt_output = backend.run(sample_input)

max_abs_diff = (torch_output.float() - trt_output.float()).abs().max().item()
mean_abs_diff = (torch_output.float() - trt_output.float()).abs().mean().item()
print(f"TensorRT INT8 sanity check: mean abs diff={mean_abs_diff:.6e}, max abs diff={max_abs_diff:.6e}")
```

Adapt for tuple/list inputs and multi-output models.

Validation guidance:

- Image restoration: SSIM, PSNR, visual samples, diff maps.
- Classification: top-1/top-5 and confidence drift.
- Detection/segmentation: mAP, IoU, mask quality, qualitative examples.
- Sequence models: task metric plus length and padding edge cases.

Do not claim success from build completion alone. A built INT8 engine still needs output validation.

## Common failures

If ONNX lacks Q/DQ nodes:

- Check that export uses the quantized copy, not the original model.
- Check that `forward_loop` actually runs model forward.
- Check calibration input dtype, shape, device, and structure.

If TensorRT build fails:

- Run ONNX checker.
- Try `trtexec --verbose --onnx=... --int8 --saveEngine=...`.
- Check unsupported ops and opset compatibility.
- Check dynamic-shape profiles are complete.
- Check CUDA, driver, TensorRT, ONNX, and ModelOpt versions.

If accuracy drops too much:

- Improve calibration representativeness.
- Increase calibration sample count.
- Verify preprocessing parity.
- Consider excluding sensitive modules from quantization.
- Compare intermediate outputs if available.

If speed does not improve:

- Exclude build and warmup time from timing.
- Check GPU utilization and batch size.
- Check whether preprocessing/postprocessing dominates runtime.
- Inspect whether TensorRT selected INT8 kernels for important layers.

## Implementation boundaries

When editing code:

- Prefer small, local changes around inference backend construction and forward invocation.
- Preserve existing CLI defaults unless they conflict with fixed TensorRT engine requirements.
- Keep generated files under an existing cache, artifact, or dummy directory when appropriate.
- Do not add broad abstractions unrelated to INT8 conversion.
- Do not silently fall back to PyTorch if TensorRT build fails; surface the failure clearly.

## If the repository has a local reference document

If a repository contains a document like `dummy/trt_int8_flow.md`, read it first and follow project-specific naming, command, cache, and validation conventions over this generic skill.
