// Flexbox layout (Yoga) behind a plain C header, for Swift.
#ifndef CFLEX_H
#define CFLEX_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FXNode *FXNodeRef;

// What a leaf (text, an image) asks for: the size it wants within `width` and
// `height`. A mode is 0 (no limit), 1 (exactly) or 2 (at most).
typedef void (*FXMeasure)(void *context, float width, int widthMode, float height, int heightMode, float *outWidth, float *outHeight);

FXNodeRef fx_new(void);
// Frees the node and every node under it.
void fx_free_tree(FXNodeRef node);
void fx_add_child(FXNodeRef parent, FXNodeRef child, int index);
void fx_set_measure(FXNodeRef node, void *context, FXMeasure measure);
// NaN for a side leaves it for the layout to find.
void fx_layout(FXNodeRef root, float width, float height);
void fx_frame(FXNodeRef node, float *x, float *y, float *width, float *height);

// 0 column, 1 column-reverse, 2 row, 3 row-reverse
void fx_direction(FXNodeRef node, int value);
// 0 no wrap, 1 wrap, 2 wrap-reverse
void fx_wrap(FXNodeRef node, int value);
// 0 start, 1 center, 2 end, 3 between, 4 around, 5 evenly
void fx_justify(FXNodeRef node, int value);
// 0 auto, 1 start, 2 center, 3 end, 4 stretch, 5 baseline, 6 between, 7 around, 8 evenly
void fx_align_items(FXNodeRef node, int value);
void fx_align_self(FXNodeRef node, int value);
void fx_align_content(FXNodeRef node, int value);
void fx_grow(FXNodeRef node, float value);
void fx_shrink(FXNodeRef node, float value);
// A length's unit: 0 points, 1 percent, 2 auto.
void fx_basis(FXNodeRef node, float value, int unit);
// 0 relative, 1 absolute
void fx_position_type(FXNodeRef node, int value);
// 0 visible, 1 hidden, 2 scroll
void fx_overflow(FXNodeRef node, int value);
// 0 flex, 1 none
void fx_display(FXNodeRef node, int value);
// A size: 0 width, 1 height, 2 min width, 3 min height, 4 max width, 5 max height.
void fx_size(FXNodeRef node, int which, float value, int unit);
// An edge: 0 left, 1 top, 2 right, 3 bottom.
void fx_padding(FXNodeRef node, int edge, float value, int unit);
void fx_margin(FXNodeRef node, int edge, float value, int unit);
void fx_border(FXNodeRef node, int edge, float value);
void fx_inset(FXNodeRef node, int edge, float value, int unit);
// A gutter: 0 between columns, 1 between rows.
void fx_gap(FXNodeRef node, int gutter, float value);
void fx_aspect(FXNodeRef node, float value);

#ifdef __cplusplus
}
#endif

#endif
