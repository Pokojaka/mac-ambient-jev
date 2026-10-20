"""Generate the deterministic ONNX test fixtures.

`affine.onnx` has typed multi-input/output nodes. `cache.onnx` grows a float32
tensor along its second axis and increments an int64 counter, so a test can feed
each output back as the next input.

Run with `uv run --with onnx python scripts/generate_onnx_fixture.py`.
"""

from pathlib import Path

import onnx
from onnx import TensorProto, helper


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIRECTORY = (
    REPOSITORY_ROOT / "app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources"
)
AFFINE_PATH = FIXTURE_DIRECTORY / "affine.onnx"
CACHE_PATH = FIXTURE_DIRECTORY / "cache.onnx"


def build_affine() -> onnx.ModelProto:
    x_info = helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 4])
    ids_info = helper.make_tensor_value_info("ids", TensorProto.INT64, [1, 3])
    sr_info = helper.make_tensor_value_info("sr", TensorProto.INT64, [])
    y_info = helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, 4])
    ids_out_info = helper.make_tensor_value_info(
        "ids_out", TensorProto.INT64, [1, 3]
    )
    sr_out_info = helper.make_tensor_value_info("sr_out", TensorProto.INT64, [])
    positive_info = helper.make_tensor_value_info(
        "positive", TensorProto.BOOL, [1, 4]
    )
    two = helper.make_tensor("two", TensorProto.FLOAT, [], [2.0])
    one = helper.make_tensor("one", TensorProto.INT64, [], [1])
    zero = helper.make_tensor("zero", TensorProto.FLOAT, [], [0.0])

    graph = helper.make_graph(
        nodes=[
            helper.make_node("Mul", ["x", "two"], ["scaled"]),
            helper.make_node("Cast", ["sr"], ["sr_float"], to=TensorProto.FLOAT),
            helper.make_node("Add", ["scaled", "sr_float"], ["y"]),
            helper.make_node("Add", ["ids", "one"], ["ids_out"]),
            helper.make_node("Identity", ["sr"], ["sr_out"]),
            helper.make_node("Greater", ["y", "zero"], ["positive"]),
        ],
        name="affine",
        inputs=[x_info, ids_info, sr_info],
        outputs=[y_info, ids_out_info, sr_out_info, positive_info],
        initializer=[two, one, zero],
    )
    model = helper.make_model(
        graph,
        producer_name="mac-ambient-jev",
        opset_imports=[helper.make_opsetid("", 13)],
    )
    model.ir_version = 8
    return model


def build_cache() -> onnx.ModelProto:
    past_info = helper.make_tensor_value_info(
        "past", TensorProto.FLOAT, [1, "past_length", 2]
    )
    step_info = helper.make_tensor_value_info("step", TensorProto.FLOAT, [1, 1, 2])
    count_info = helper.make_tensor_value_info("count", TensorProto.INT64, [1])
    present_info = helper.make_tensor_value_info(
        "present", TensorProto.FLOAT, [1, "present_length", 2]
    )
    count_out_info = helper.make_tensor_value_info(
        "count_out", TensorProto.INT64, [1]
    )
    one = helper.make_tensor("one", TensorProto.INT64, [], [1])

    graph = helper.make_graph(
        nodes=[
            helper.make_node("Concat", ["past", "step"], ["present"], axis=1),
            helper.make_node("Add", ["count", "one"], ["count_out"]),
        ],
        name="cache",
        inputs=[past_info, step_info, count_info],
        outputs=[present_info, count_out_info],
        initializer=[one],
    )
    model = helper.make_model(
        graph,
        producer_name="mac-ambient-jev",
        opset_imports=[helper.make_opsetid("", 13)],
    )
    model.ir_version = 8
    return model


def write_fixture(model: onnx.ModelProto, path: Path) -> None:
    onnx.checker.check_model(model)
    serialized = model.SerializeToString(deterministic=True)
    if len(serialized) >= 10_000:
        raise ValueError(f"Serialized fixture is too large: {len(serialized)} bytes")

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(serialized)
    print(f"生成先: {path}")
    print(f"ファイルサイズ: {len(serialized)} バイト")


def main() -> None:
    write_fixture(build_affine(), AFFINE_PATH)
    write_fixture(build_cache(), CACHE_PATH)


if __name__ == "__main__":
    main()
