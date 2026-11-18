#include "cflex.h"
#include <yoga/Yoga.h>
#include <cmath>

namespace {

struct Leaf {
    void *context;
    FXMeasure measure;
};

YGNodeRef yg(FXNodeRef node) { return reinterpret_cast<YGNodeRef>(node); }

YGSize measureLeaf(YGNodeConstRef node, float width, YGMeasureMode widthMode, float height, YGMeasureMode heightMode) {
    auto *leaf = static_cast<Leaf *>(YGNodeGetContext(node));
    float w = 0, h = 0;
    auto mode = [](YGMeasureMode m) { return m == YGMeasureModeExactly ? 1 : m == YGMeasureModeAtMost ? 2 : 0; };
    if (leaf != nullptr && leaf->measure != nullptr) {
        leaf->measure(leaf->context, width, mode(widthMode), height, mode(heightMode), &w, &h);
    }
    return YGSize{w, h};
}

void freeLeaves(YGNodeRef node) {
    auto *leaf = static_cast<Leaf *>(YGNodeGetContext(node));
    delete leaf;
    YGNodeSetContext(node, nullptr);
    const size_t count = YGNodeGetChildCount(node);
    for (size_t i = 0; i < count; i++) freeLeaves(YGNodeGetChild(node, i));
}

// As on the web, which the mods' flex rules are written for: rows by
// default, and children that shrink.
YGConfigRef config() {
    static YGConfigRef shared = [] {
        YGConfigRef c = YGConfigNew();
        YGConfigSetUseWebDefaults(c, true);
        YGConfigSetPointScaleFactor(c, 2);
        return c;
    }();
    return shared;
}

YGEdge edge(int e) {
    switch (e) {
        case 0: return YGEdgeLeft;
        case 1: return YGEdgeTop;
        case 2: return YGEdgeRight;
        default: return YGEdgeBottom;
    }
}

YGAlign align(int v) {
    switch (v) {
        case 1: return YGAlignFlexStart;
        case 2: return YGAlignCenter;
        case 3: return YGAlignFlexEnd;
        case 4: return YGAlignStretch;
        case 5: return YGAlignBaseline;
        case 6: return YGAlignSpaceBetween;
        case 7: return YGAlignSpaceAround;
        case 8: return YGAlignSpaceEvenly;
        default: return YGAlignAuto;
    }
}

}  // namespace

extern "C" {

FXNodeRef fx_new(void) { return reinterpret_cast<FXNodeRef>(YGNodeNewWithConfig(config())); }

void fx_free_tree(FXNodeRef node) {
    freeLeaves(yg(node));
    YGNodeFreeRecursive(yg(node));
}

void fx_add_child(FXNodeRef parent, FXNodeRef child, int index) { YGNodeInsertChild(yg(parent), yg(child), static_cast<size_t>(index)); }

void fx_set_measure(FXNodeRef node, void *context, FXMeasure measure) {
    delete static_cast<Leaf *>(YGNodeGetContext(yg(node)));
    YGNodeSetContext(yg(node), new Leaf{context, measure});
    YGNodeSetMeasureFunc(yg(node), measureLeaf);
}

void fx_layout(FXNodeRef root, float width, float height) {
    YGNodeCalculateLayout(yg(root), std::isnan(width) ? YGUndefined : width, std::isnan(height) ? YGUndefined : height, YGDirectionLTR);
}

void fx_frame(FXNodeRef node, float *x, float *y, float *width, float *height) {
    *x = YGNodeLayoutGetLeft(yg(node));
    *y = YGNodeLayoutGetTop(yg(node));
    *width = YGNodeLayoutGetWidth(yg(node));
    *height = YGNodeLayoutGetHeight(yg(node));
}

void fx_direction(FXNodeRef node, int value) {
    static const YGFlexDirection table[] = {YGFlexDirectionColumn, YGFlexDirectionColumnReverse, YGFlexDirectionRow, YGFlexDirectionRowReverse};
    YGNodeStyleSetFlexDirection(yg(node), table[value & 3]);
}

void fx_wrap(FXNodeRef node, int value) {
    YGNodeStyleSetFlexWrap(yg(node), value == 1 ? YGWrapWrap : value == 2 ? YGWrapWrapReverse : YGWrapNoWrap);
}

void fx_justify(FXNodeRef node, int value) {
    static const YGJustify table[] = {YGJustifyFlexStart, YGJustifyCenter, YGJustifyFlexEnd, YGJustifySpaceBetween, YGJustifySpaceAround, YGJustifySpaceEvenly};
    YGNodeStyleSetJustifyContent(yg(node), table[value < 0 || value > 5 ? 0 : value]);
}

void fx_align_items(FXNodeRef node, int value) { YGNodeStyleSetAlignItems(yg(node), align(value)); }
void fx_align_self(FXNodeRef node, int value) { YGNodeStyleSetAlignSelf(yg(node), align(value)); }
void fx_align_content(FXNodeRef node, int value) { YGNodeStyleSetAlignContent(yg(node), align(value)); }
void fx_grow(FXNodeRef node, float value) { YGNodeStyleSetFlexGrow(yg(node), value); }
void fx_shrink(FXNodeRef node, float value) { YGNodeStyleSetFlexShrink(yg(node), value); }

void fx_basis(FXNodeRef node, float value, int unit) {
    if (unit == 2) YGNodeStyleSetFlexBasisAuto(yg(node));
    else if (unit == 1) YGNodeStyleSetFlexBasisPercent(yg(node), value);
    else YGNodeStyleSetFlexBasis(yg(node), value);
}

void fx_position_type(FXNodeRef node, int value) { YGNodeStyleSetPositionType(yg(node), value == 1 ? YGPositionTypeAbsolute : YGPositionTypeRelative); }
void fx_overflow(FXNodeRef node, int value) { YGNodeStyleSetOverflow(yg(node), value == 1 ? YGOverflowHidden : value == 2 ? YGOverflowScroll : YGOverflowVisible); }
void fx_display(FXNodeRef node, int value) { YGNodeStyleSetDisplay(yg(node), value == 1 ? YGDisplayNone : YGDisplayFlex); }

void fx_size(FXNodeRef node, int which, float value, int unit) {
    YGNodeRef n = yg(node);
    switch (which) {
        case 0: if (unit == 2) YGNodeStyleSetWidthAuto(n); else if (unit == 1) YGNodeStyleSetWidthPercent(n, value); else YGNodeStyleSetWidth(n, value); break;
        case 1: if (unit == 2) YGNodeStyleSetHeightAuto(n); else if (unit == 1) YGNodeStyleSetHeightPercent(n, value); else YGNodeStyleSetHeight(n, value); break;
        case 2: if (unit == 1) YGNodeStyleSetMinWidthPercent(n, value); else if (unit == 0) YGNodeStyleSetMinWidth(n, value); break;
        case 3: if (unit == 1) YGNodeStyleSetMinHeightPercent(n, value); else if (unit == 0) YGNodeStyleSetMinHeight(n, value); break;
        case 4: if (unit == 1) YGNodeStyleSetMaxWidthPercent(n, value); else if (unit == 0) YGNodeStyleSetMaxWidth(n, value); break;
        default: if (unit == 1) YGNodeStyleSetMaxHeightPercent(n, value); else if (unit == 0) YGNodeStyleSetMaxHeight(n, value); break;
    }
}

void fx_padding(FXNodeRef node, int e, float value, int unit) {
    if (unit == 1) YGNodeStyleSetPaddingPercent(yg(node), edge(e), value);
    else YGNodeStyleSetPadding(yg(node), edge(e), value);
}

void fx_margin(FXNodeRef node, int e, float value, int unit) {
    if (unit == 2) YGNodeStyleSetMarginAuto(yg(node), edge(e));
    else if (unit == 1) YGNodeStyleSetMarginPercent(yg(node), edge(e), value);
    else YGNodeStyleSetMargin(yg(node), edge(e), value);
}

void fx_border(FXNodeRef node, int e, float value) { YGNodeStyleSetBorder(yg(node), edge(e), value); }

void fx_inset(FXNodeRef node, int e, float value, int unit) {
    if (unit == 2) YGNodeStyleSetPositionAuto(yg(node), edge(e));
    else if (unit == 1) YGNodeStyleSetPositionPercent(yg(node), edge(e), value);
    else YGNodeStyleSetPosition(yg(node), edge(e), value);
}

void fx_gap(FXNodeRef node, int gutter, float value) { YGNodeStyleSetGap(yg(node), gutter == 0 ? YGGutterColumn : YGGutterRow, value); }
void fx_aspect(FXNodeRef node, float value) { YGNodeStyleSetAspectRatio(yg(node), value); }

}
