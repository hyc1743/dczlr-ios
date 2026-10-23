#include "dc_xx.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct dc_xx {
    const uint8_t *data;
    size_t length;
    dc_xx_info info;
    dc_xx_node *nodes;
    dc_xx_submesh *meshes;
    dc_xx_material *materials;
    dc_xx_texture *textures;
};
typedef struct reader {
    const uint8_t *data;
    size_t length, at;
    dc_xx_info counts;
    dc_xx *model;
} reader;
static uint32_t word(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static int overlap(const void *a, size_t al, const void *b, size_t bl) {
    uintptr_t aa = (uintptr_t)a, bb = (uintptr_t)b;
    return al && bl && (aa <= bb ? bb - aa < al : aa - bb < bl);
}
static int skip(reader *r, size_t bytes) {
    if (bytes > r->length - r->at) return 0;
    r->at += bytes;
    return 1;
}
static int integer(reader *r, uint32_t *out) {
    if (r->length - r->at < 4) return 0;
    *out = word(r->data + r->at);
    r->at += 4;
    return 1;
}
static int array(reader *r, uint32_t count, size_t stride, dc_xx_span *out) {
    if (count > (r->length - r->at) / stride) return 0;
    if (out) *out = (dc_xx_span){r->at, (size_t)count * stride};
    return skip(r, (size_t)count * stride);
}
static int name(reader *r, dc_xx_span *out) {
    uint32_t length;
    if (!integer(r, &length)) return 0;
    *out = (dc_xx_span){r->at, length};
    return skip(r, length);
}
#define CHECK(expression) do { if (!(expression)) return DC_FORMAT; } while (0)

static dc_status node(reader *r, uint32_t parent, uint32_t depth) {
    if (depth > DC_XX_DEPTH_LIMIT || r->counts.nodes >= DC_XX_NODE_LIMIT) return DC_RANGE;
    uint32_t index = r->counts.nodes++;
    dc_xx_node n = {0};
    n.parent = parent;
    CHECK(name(r, &n.name) && integer(r, &n.children));
    if (n.children > DC_XX_NODE_LIMIT) return DC_RANGE;
    n.matrix_offset = r->at;
    CHECK(skip(r, 80) && integer(r, &n.submeshes) && skip(r, 40));
    n.first_submesh = r->counts.submeshes;
    if (n.submeshes > DC_XX_SUBMESH_LIMIT - r->counts.submeshes) return DC_RANGE;
    if (r->model) r->model->nodes[index] = n;
    if (n.submeshes) {
        CHECK(r->at < r->length);
        uint32_t uv_sets = r->data[r->at++];
        if (uv_sets > 3) return DC_FORMAT;
        for (uint32_t i = 0; i < n.submeshes; ++i) {
            dc_xx_submesh m = {0};
            m.node = index;
            m.uv_sets = uv_sets;
            CHECK(skip(r, 16) && integer(r, &m.material) && integer(r, &m.index_count));
            CHECK(array(r, m.index_count, 2, &m.indices) && integer(r, &m.vertex_count));
            CHECK(array(r, m.vertex_count, 52, &m.vertices));
            for (uint32_t j = 0; j < uv_sets; ++j) CHECK(array(r, m.vertex_count, 8, &m.extra_uv[j]));
            if (r->model) r->model->meshes[r->counts.submeshes] = m;
            ++r->counts.submeshes;
        }
        CHECK(r->length - r->at >= 2);
        uint32_t shared = (uint32_t)r->data[r->at] | (uint32_t)r->data[r->at + 1] << 8;
        r->at += 2;
        CHECK(skip(r, 8) && array(r, shared, 52, NULL));
        uint32_t bones;
        CHECK(integer(r, &bones));
        if (bones > DC_XX_NODE_LIMIT - r->counts.bones) return DC_RANGE;
        r->counts.bones += bones;
        for (uint32_t i = 0; i < bones; ++i) {
            dc_xx_span unused;
            CHECK(name(r, &unused) && skip(r, 68));
        }
    }
    for (uint32_t i = 0; i < n.children; ++i) {
        dc_status status = node(r, index, depth + 1);
        if (status != DC_OK) return status;
    }
    return DC_OK;
}

static dc_status parse(reader *r) {
    CHECK(r->length >= 21 && (word(r->data) == 0x404c28f6u || word(r->data) == 0x404ae148u));
    r->counts.version_bits = word(r->data);
    r->at = 21;
    dc_status status = node(r, DC_XX_NO_PARENT, 0);
    if (status != DC_OK) return status;
    CHECK(skip(r, 4) && integer(r, &r->counts.materials));
    if (r->counts.materials > DC_XX_MATERIAL_LIMIT) return DC_RANGE;
    for (uint32_t i = 0; i < r->counts.materials; ++i) {
        dc_xx_material m = {0};
        CHECK(name(r, &m.name));
        m.value_offset = r->at;
        CHECK(skip(r, 68));
        for (uint32_t j = 0; j < 8; ++j) {
            if (j == 4) CHECK(skip(r, 4));
            CHECK(name(r, &m.texture_names[j]) && skip(r, 16));
        }
        CHECK(skip(r, 4));
        if (r->model) r->model->materials[i] = m;
    }
    CHECK(integer(r, &r->counts.textures));
    if (r->counts.textures > DC_XX_TEXTURE_LIMIT) return DC_RANGE;
    for (uint32_t i = 0; i < r->counts.textures; ++i) {
        dc_xx_texture t = {0};
        uint32_t bytes;
        CHECK(name(r, &t.name));
        t.descriptor_offset = r->at;
        CHECK(skip(r, 33) && integer(r, &bytes));
        t.image = (dc_xx_span){r->at, bytes};
        CHECK(skip(r, bytes));
        if (r->model) r->model->textures[i] = t;
    }
    r->counts.parsed_bytes = r->at;
    r->counts.opaque_tail = (dc_xx_span){r->at, r->length - r->at};
    return DC_OK;
}

dc_status dc_xx_probe(const void *bytes, size_t length, dc_xx_info *out) {
    if (!bytes || !out || overlap(bytes, length, out, sizeof(*out))) return DC_ARGUMENT;
    reader r = {.data = bytes, .length = length};
    dc_status status = parse(&r);
    if (status == DC_OK) *out = r.counts;
    return status;
}

void dc_xx_close(dc_xx *model) {
    if (!model) return;
    free(model->nodes); free(model->meshes); free(model->materials); free(model->textures);
    free(model);
}
dc_status dc_xx_open(const void *bytes, size_t length, dc_xx **out) {
    if (!out || overlap(bytes, length, out, sizeof(*out))) return DC_ARGUMENT;
    *out = NULL;
    dc_xx_info info;
    dc_status status = dc_xx_probe(bytes, length, &info);
    if (status != DC_OK) return status;
    dc_xx *m = calloc(1, sizeof(*m));
    if (!m) return DC_MEMORY;
    m->data = bytes; m->length = length; m->info = info;
    m->nodes = calloc(info.nodes, sizeof(*m->nodes));
    m->meshes = calloc(info.submeshes ? info.submeshes : 1, sizeof(*m->meshes));
    m->materials = calloc(info.materials ? info.materials : 1, sizeof(*m->materials));
    m->textures = calloc(info.textures ? info.textures : 1, sizeof(*m->textures));
    if (!m->nodes || !m->meshes || !m->materials || !m->textures) { dc_xx_close(m); return DC_MEMORY; }
    reader r = {.data = bytes, .length = length, .model = m};
    status = parse(&r);
    if (status != DC_OK) { dc_xx_close(m); return status; }
    *out = m;
    return DC_OK;
}
dc_status dc_xx_get_info(const dc_xx *model, dc_xx_info *out) {
    if (!model || !out) return DC_ARGUMENT;
    if (overlap(model->data, model->length, out, sizeof(*out))) return DC_ARGUMENT;
    *out = model->info;
    return DC_OK;
}
#define GETTER(kind, type, field, count) \
dc_status dc_xx_##kind##_at(const dc_xx *model, uint32_t index, type *out) { \
    if (!model || !out) return DC_ARGUMENT; \
    if (overlap(model->data, model->length, out, sizeof(*out))) return DC_ARGUMENT; \
    if (index >= model->info.count) return DC_RANGE; \
    *out = model->field[index]; return DC_OK; \
}
GETTER(node, dc_xx_node, nodes, nodes)
GETTER(submesh, dc_xx_submesh, meshes, submeshes)
GETTER(material, dc_xx_material, materials, materials)
GETTER(texture, dc_xx_texture, textures, textures)

static int string_length(const uint8_t *bytes, size_t capacity, size_t *length) {
    for (size_t i = 0; i < capacity; ++i) if (bytes[i] == 255) { *length = i; return 1; }
    return 0;
}
dc_status dc_xx_find_material_encoded(const dc_xx *model,
        const void *name_bytes, size_t length, uint32_t *index) {
    if (!model || !name_bytes || !index) return DC_ARGUMENT;
    if (overlap(model->data, model->length, index, sizeof(*index))) return DC_ARGUMENT;
    size_t query;
    if (!string_length(name_bytes, length, &query)) return DC_FORMAT;
    for (uint32_t i = 0; i < model->info.materials; ++i) {
        dc_xx_span span = model->materials[i].name;
        size_t candidate;
        if (!string_length(model->data + span.offset, span.length, &candidate)) return DC_FORMAT;
        if (candidate == query && !memcmp(model->data + span.offset, name_bytes, query)) { *index = i; return DC_OK; }
    }
    return DC_NOT_FOUND;
}
dc_status dc_xx_material_baseline(const dc_xx *model, uint32_t index, dc_material_value *out) {
    if (!model || !out) return DC_ARGUMENT;
    if (overlap(model->data, model->length, out, sizeof(*out))) return DC_ARGUMENT;
    if (index >= model->info.materials) return DC_RANGE;
    dc_material_value value;
    const uint8_t *p = model->data + model->materials[index].value_offset;
    for (uint32_t i = 0; i < DC_MATERIAL_COMPONENTS; ++i) {
        uint32_t bits = word(p + i * 4);
        memcpy(&value.components[i], &bits, 4);
        if (!isfinite(value.components[i])) return DC_RANGE;
        if (i < 16) value.components[i] = -value.components[i];
    }
    *out = value;
    return DC_OK;
}

dc_status dc_xx_find_node_encoded(const dc_xx *model, const void *name_bytes, size_t length, uint32_t *index) {
    if (!model || !name_bytes || !index) return DC_ARGUMENT;
    if (overlap(model->data, model->length, index, sizeof(*index))) return DC_ARGUMENT;
    size_t query;
    if (!string_length(name_bytes, length, &query)) return DC_FORMAT;
    uint32_t selected = UINT32_MAX;
    for (uint32_t i = 0; i < model->info.nodes; ++i) {
        dc_xx_span span = model->nodes[i].name;
        size_t candidate;
        if (!string_length(model->data + span.offset, span.length, &candidate)) return DC_FORMAT;
        if (candidate == query && !memcmp(model->data + span.offset, name_bytes, query)) selected = i;
    }
    if (selected == UINT32_MAX) return DC_NOT_FOUND;
    *index = selected;
    return DC_OK;
}

dc_status dc_xx_node_matrix(const dc_xx *model, uint32_t index, dc_matrix *out) {
    if (!model || !out) return DC_ARGUMENT;
    if (overlap(model->data, model->length, out, sizeof(*out))) return DC_ARGUMENT;
    if (index >= model->info.nodes) return DC_RANGE;
    dc_matrix value;
    const uint8_t *p = model->data + model->nodes[index].matrix_offset;
    for (uint32_t i = 0; i < 16; ++i) {
        uint32_t bits = word(p + i*4);
        memcpy(&value.values[i], &bits, 4);
        if (!isfinite(value.values[i])) return DC_RANGE;
    }
    *out = value;
    return DC_OK;
}

static dc_status image_format(const dc_xx *model, uint32_t index, dc_image_format *out) {
    if (!model) return DC_ARGUMENT;
    if (index >= model->info.textures) return DC_RANGE;
    dc_xx_span n = model->textures[index].name;
    size_t length;
    if (!string_length(model->data + n.offset, n.length, &length) || length < 4) return DC_FORMAT;
    char suffix[4];
    for (uint32_t i = 0; i < 4; ++i) suffix[i] = (char)(model->data[n.offset + length - 4 + i] ^ 255);
    if (!memcmp(suffix, ".bmp", 4)) *out = DC_IMAGE_XX_BMP;
    else if (!memcmp(suffix, ".tga", 4)) *out = DC_IMAGE_TGA;
    else return DC_FORMAT;
    return DC_OK;
}
dc_status dc_xx_image_probe(const dc_xx *model, uint32_t index, dc_image_info *out) {
    if (!model || !out) return DC_ARGUMENT;
    if (overlap(model->data, model->length, out, sizeof(*out))) return DC_ARGUMENT;
    dc_image_format format;
    dc_status status = image_format(model, index, &format);
    if (status != DC_OK) return status;
    dc_xx_span span = model->textures[index].image;
    return dc_image_probe(model->data + span.offset, span.length, format, out);
}
dc_status dc_xx_image_decode(const dc_xx *model, uint32_t index, void *rgba, size_t capacity, dc_image_info *out) {
    if (!model || !rgba) return DC_ARGUMENT;
    if (out && overlap(model->data, model->length, out, sizeof(*out))) return DC_ARGUMENT;
    dc_image_format format;
    dc_status status = image_format(model, index, &format);
    if (status != DC_OK) return status;
    if (overlap(model->data, model->length, rgba, capacity)) return DC_ARGUMENT;
    dc_xx_span span = model->textures[index].image;
    return dc_image_decode(model->data + span.offset, span.length, format, rgba, capacity, out);
}
