#include "dc_mesh.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct clip_vertex { double p[4],uv[2]; } clip_vertex;

static int overlaps(const void *a,size_t al,const void *b,size_t bl) {
    uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;
    return al && bl && (aa<=bb ? bb-aa<al : aa-bb<bl);
}

static double distance_to_plane(const clip_vertex *v,unsigned plane) {
    unsigned axis=plane/2;
    if (plane==4) return v->p[2];
    return (plane&1) ? v->p[3]-v->p[axis] : v->p[3]+v->p[axis];
}

static dc_status clip_triangle(clip_vertex *polygon,size_t *count) {
    clip_vertex scratch[10];
    for (unsigned plane=0;plane<6 && *count;++plane) {
        size_t produced=0;
        clip_vertex previous=polygon[*count-1];
        double pd=distance_to_plane(&previous,plane);
        for (size_t j=0;j<*count;++j) {
            clip_vertex current=polygon[j];
            double cd=distance_to_plane(&current,plane);
            if ((pd>=0)!=(cd>=0)) {
                if (produced>=10) return DC_RANGE;
                double t=pd/(pd-cd);
                clip_vertex v;
                for (unsigned k=0;k<4;++k) v.p[k]=(1-t)*previous.p[k]+t*current.p[k];
                for (unsigned k=0;k<2;++k) v.uv[k]=(1-t)*previous.uv[k]+t*current.uv[k];
                /* Put the intersection exactly on its clipping plane. */
                v.p[plane/2]=plane==4 ? 0 : (plane&1) ? v.p[3] : -v.p[3];
                scratch[produced++]=v;
            }
            if (cd>=0) {
                if (produced>=10) return DC_RANGE;
                scratch[produced++]=current;
            }
            previous=current;pd=cd;
        }
        memcpy(polygon,scratch,produced*sizeof(*polygon));
        *count=produced;
    }
    return DC_OK;
}

dc_status dc_mesh_clip_project(const dc_mesh_vertex *vertices,size_t vertex_count,
        const uint16_t *indices,size_t index_count,const dc_matrix *mvp,
        const dc_viewport *viewport,uint32_t diffuse,dc_sprite_vertex *out,size_t capacity,
        size_t *written) {
    if (!vertices || !indices || !mvp || !viewport || !written || (!out && capacity)) return DC_ARGUMENT;
    if (!vertex_count || vertex_count>1048576 || !index_count || index_count>1048576 ||
        index_count%3 || capacity>1048576) return DC_RANGE;
    const void *inputs[]={vertices,indices,mvp,viewport};
    size_t lengths[]={vertex_count*sizeof(*vertices),index_count*sizeof(*indices),sizeof(*mvp),sizeof(*viewport)};
    size_t bytes=capacity*sizeof(*out);
    if (out && overlaps(out,bytes,written,sizeof(*written))) return DC_ARGUMENT;
    for (unsigned i=0;i<4;++i) if ((out && overlaps(inputs[i],lengths[i],out,bytes)) ||
        overlaps(inputs[i],lengths[i],written,sizeof(*written))) return DC_ARGUMENT;
    const float *view=&viewport->x;
    for (unsigned i=0;i<6;++i) if (!isfinite(view[i])) return DC_RANGE;
    if (viewport->width<=0 || viewport->height<=0 || viewport->min_z<0 || viewport->max_z>1 ||
        viewport->min_z>viewport->max_z) return DC_RANGE;
    for (unsigned i=0;i<16;++i) if (!isfinite(mvp->values[i])) return DC_RANGE;
    dc_sprite_vertex *result=out && bytes ? malloc(bytes) : NULL;
    if (out && bytes && !result) return DC_MEMORY;
    dc_status status=DC_OK;
    size_t total=0;
    for (size_t triangle=0;triangle<index_count && status==DC_OK;triangle+=3) {
        clip_vertex polygon[10];
        for (unsigned j=0;j<3;++j) {
            uint16_t index=indices[triangle+j];
            if (index>=vertex_count) { status=DC_RANGE;break; }
            const dc_mesh_vertex *v=&vertices[index];
            if (!isfinite(v->uv[0]) || !isfinite(v->uv[1])) { status=DC_RANGE;break; }
            float p[4]={v->position[0],v->position[1],v->position[2],1};
            for (unsigned k=0;k<4;++k) if (!isfinite(p[k])) status=DC_RANGE;
            if (status!=DC_OK) break;
            for (unsigned col=0;col<4;++col) {
                float sum=0;
                for (unsigned k=0;k<4;++k) {
                    volatile float product=p[k]*mvp->values[k*4+col];
                    sum+=product;
                }
                if (!isfinite(sum)) { status=DC_RANGE;break; }
                polygon[j].p[col]=sum;
            }
            polygon[j].uv[0]=v->uv[0];polygon[j].uv[1]=v->uv[1];
        }
        if (status!=DC_OK) break;
        size_t count=3;
        status=clip_triangle(polygon,&count);
        if (status!=DC_OK || count<3) continue;
        size_t added=(count-2)*3;
        if (added>1048576-total || (out && added>capacity-total)) { status=DC_RANGE;break; }
        dc_sprite_vertex projected[10];
        for (size_t j=0;j<count;++j) {
            const clip_vertex *v=&polygon[j];
            if (!(v->p[3]>0)) { status=DC_RANGE;break; }
            double rw=1/v->p[3];
            projected[j]=(dc_sprite_vertex){
                .x=(float)(viewport->x+(v->p[0]*rw+1)*viewport->width*.5),
                .y=(float)(viewport->y+(1-v->p[1]*rw)*viewport->height*.5),
                .z=(float)(viewport->min_z+v->p[2]*rw*(viewport->max_z-viewport->min_z)),
                .rhw=(float)rw,.diffuse=diffuse,.u=(float)v->uv[0],.v=(float)v->uv[1]};
            const dc_sprite_vertex *p=&projected[j];
            if (!isfinite(p->x) || !isfinite(p->y) || !isfinite(p->z) || !isfinite(p->rhw) ||
                p->rhw<=0 || !isfinite(p->u) || !isfinite(p->v)) { status=DC_RANGE;break; }
        }
        if (status!=DC_OK) break;
        if (out) for (size_t j=1;j+1<count;++j) {
            result[total++]=projected[0];result[total++]=projected[j];result[total++]=projected[j+1];
        }
        else total+=added;
    }
    if (status==DC_OK) {
        if (total && out) memcpy(out,result,total*sizeof(*out));
        *written=total;
    }
    free(result);
    return status;
}

typedef struct lit_clip_vertex {
    double p[4], uv[2], sheen_uv[2], rgba[4], spec[3];
} lit_clip_vertex;

static double lit_distance_to_plane(const lit_clip_vertex *v, unsigned plane) {
    unsigned axis = plane / 2;
    if (plane == 4) return v->p[2];
    return (plane & 1) ? v->p[3] - v->p[axis] : v->p[3] + v->p[axis];
}

static dc_status clip_lit_triangle(lit_clip_vertex *polygon, size_t *count) {
    lit_clip_vertex scratch[10];
    for (unsigned plane = 0; plane < 6 && *count; ++plane) {
        size_t produced = 0;
        lit_clip_vertex previous = polygon[*count - 1];
        double pd = lit_distance_to_plane(&previous, plane);
        for (size_t j = 0; j < *count; ++j) {
            lit_clip_vertex current = polygon[j];
            double cd = lit_distance_to_plane(&current, plane);
            if ((pd >= 0) != (cd >= 0)) {
                if (produced >= 10) return DC_RANGE;
                double t = pd / (pd - cd), om = 1.0 - t;
                lit_clip_vertex v;
                for (unsigned k = 0; k < 4; ++k) v.p[k] = om * previous.p[k] + t * current.p[k];
                for (unsigned k = 0; k < 2; ++k) v.uv[k] = om * previous.uv[k] + t * current.uv[k];
                for (unsigned k = 0; k < 2; ++k) v.sheen_uv[k] = om * previous.sheen_uv[k] + t * current.sheen_uv[k];
                for (unsigned k = 0; k < 4; ++k) v.rgba[k] = om * previous.rgba[k] + t * current.rgba[k];
                for (unsigned k = 0; k < 3; ++k) v.spec[k] = om * previous.spec[k] + t * current.spec[k];
                v.p[plane / 2] = plane == 4 ? 0 : (plane & 1) ? v.p[3] : -v.p[3];
                scratch[produced++] = v;
            }
            if (cd >= 0) {
                if (produced >= 10) return DC_RANGE;
                scratch[produced++] = current;
            }
            previous = current;
            pd = cd;
        }
        memcpy(polygon, scratch, produced * sizeof(*polygon));
        *count = produced;
    }
    return DC_OK;
}

static uint32_t pack_d3d_color(double r, double g, double b, double a) {
    double ch[4] = {b, g, r, a};
    uint32_t out = 0;
    for (unsigned i = 0; i < 4; ++i) {
        double c = ch[i] < 0.0 ? 0.0 : (ch[i] > 1.0 ? 1.0 : ch[i]);
        uint32_t byte = (uint32_t)(c * 255.0 + 0.5);
        if (byte > 255u) byte = 255u;
        out |= byte << (i * 8u);
    }
    return out;
}

static void build_normal_matrix(const dc_matrix *world, float nmat[9]) {
    if (!world) {
        memset(nmat, 0, 9 * sizeof(float));
        nmat[0] = nmat[4] = nmat[8] = 1.0f;
        return;
    }
    const float *m = world->values;
    float a00 = m[0], a01 = m[1], a02 = m[2];
    float a10 = m[4], a11 = m[5], a12 = m[6];
    float a20 = m[8], a21 = m[9], a22 = m[10];
    float c00 = a11 * a22 - a12 * a21;
    float c01 = a12 * a20 - a10 * a22;
    float c02 = a10 * a21 - a11 * a20;
    float det = a00 * c00 + a01 * c01 + a02 * c02;
    if (fabsf(det) > 1e-8f) {
        float s = det >= 0.0f ? 1.0f : -1.0f;
        nmat[0] = c00 * s;
        nmat[1] = c01 * s;
        nmat[2] = c02 * s;
        nmat[3] = (a02 * a21 - a01 * a22) * s;
        nmat[4] = (a00 * a22 - a02 * a20) * s;
        nmat[5] = (a01 * a20 - a00 * a21) * s;
        nmat[6] = (a01 * a12 - a02 * a11) * s;
        nmat[7] = (a02 * a10 - a00 * a12) * s;
        nmat[8] = (a00 * a11 - a01 * a10) * s;
    } else {
        nmat[0] = a00; nmat[1] = a01; nmat[2] = a02;
        nmat[3] = a10; nmat[4] = a11; nmat[5] = a12;
        nmat[6] = a20; nmat[7] = a21; nmat[8] = a22;
    }
}

static void shade_vertex(const dc_mesh_vertex *v, const dc_matrix *world, const float nmat[9],
                         const dc_material_value *mat, const dc_light_rig *rig,
                         double out_rgba[4], double out_spec[3], double out_sheen_uv[2]) {
    float wp[3], wn[3];
    if (world) {
        const float *m = world->values;
        wp[0] = v->position[0] * m[0] + v->position[1] * m[4] + v->position[2] * m[8] + m[12];
        wp[1] = v->position[0] * m[1] + v->position[1] * m[5] + v->position[2] * m[9] + m[13];
        wp[2] = v->position[0] * m[2] + v->position[1] * m[6] + v->position[2] * m[10] + m[14];
        wn[0] = v->normal[0] * nmat[0] + v->normal[1] * nmat[3] + v->normal[2] * nmat[6];
        wn[1] = v->normal[0] * nmat[1] + v->normal[1] * nmat[4] + v->normal[2] * nmat[7];
        wn[2] = v->normal[0] * nmat[2] + v->normal[1] * nmat[5] + v->normal[2] * nmat[8];
    } else {
        wp[0] = v->position[0]; wp[1] = v->position[1]; wp[2] = v->position[2];
        wn[0] = v->normal[0];   wn[1] = v->normal[1];   wn[2] = v->normal[2];
    }
    float nlen = sqrtf(wn[0] * wn[0] + wn[1] * wn[1] + wn[2] * wn[2]);
    if (isfinite(nlen) && nlen > 1e-8f) {
        float inv = 1.0f / nlen;
        wn[0] *= inv; wn[1] *= inv; wn[2] *= inv;
    } else {
        wn[0] = 0.0f; wn[1] = 1.0f; wn[2] = 0.0f;
    }

    const float *mc = mat->components;
    float m_diff[3] = {mc[0], mc[1], mc[2]};
    float m_alpha = fminf(1.0f, fmaxf(0.0f, mc[3]));
    float m_amb[3] = {mc[4], mc[5], mc[6]};
    float m_spec[3] = {mc[8], mc[9], mc[10]};
    float m_emi[3] = {mc[12], mc[13], mc[14]};
    float m_power = mc[16];

    float vx = rig->camera_eye[0] - wp[0];
    float vy = rig->camera_eye[1] - wp[1];
    float vz = rig->camera_eye[2] - wp[2];
    float vlen = sqrtf(vx * vx + vy * vy + vz * vz);
    if (isfinite(vlen) && vlen > 1e-8f) {
        float inv = 1.0f / vlen;
        vx *= inv; vy *= inv; vz *= inv;
    } else {
        vx = 0.0f; vy = 0.0f; vz = 1.0f;
    }

    float diff[3] = {
        m_amb[0] * rig->global_ambient[0] + m_emi[0],
        m_amb[1] * rig->global_ambient[1] + m_emi[1],
        m_amb[2] * rig->global_ambient[2] + m_emi[2]
    };
    float spec[3] = {0.0f, 0.0f, 0.0f};
    uint32_t lcount = rig->count > DC_LIGHT_RIG_MAX ? DC_LIGHT_RIG_MAX : rig->count;
    for (uint32_t i = 0; i < lcount; ++i) {
        const dc_light_entry *lt = &rig->lights[i];
        float lx = 0.0f, ly = 1.0f, lz = 0.0f, att = 1.0f;
        if (lt->d3d_type == 3u) {
            lx = -lt->direction[0]; ly = -lt->direction[1]; lz = -lt->direction[2];
            float dl = sqrtf(lx * lx + ly * ly + lz * lz);
            if (isfinite(dl) && dl > 1e-8f) { lx /= dl; ly /= dl; lz /= dl; }
            else continue;
        } else {
            float dx = lt->position[0] - wp[0];
            float dy = lt->position[1] - wp[1];
            float dz = lt->position[2] - wp[2];
            float d = sqrtf(dx * dx + dy * dy + dz * dz);
            if (!isfinite(d) || (lt->range > 0.0f && d > lt->range)) continue;
            if (d > 1e-7f) {
                float inv = 1.0f / d;
                lx = dx * inv; ly = dy * inv; lz = dz * inv;
            }
            float denom = lt->attenuation[0] + lt->attenuation[1] * d + lt->attenuation[2] * d * d;
            att = (isfinite(denom) && denom > 1e-6f) ? (1.0f / denom) : 1.0f;
            if (lt->d3d_type == 2u) {
                float sdx = lt->direction[0], sdy = lt->direction[1], sdz = lt->direction[2];
                float sdl = sqrtf(sdx * sdx + sdy * sdy + sdz * sdz);
                if (isfinite(sdl) && sdl > 1e-8f) {
                    sdx /= sdl; sdy /= sdl; sdz /= sdl;
                    float rho = -(lx * sdx + ly * sdy + lz * sdz);
                    float cphi = cosf(0.5f * lt->phi), ctheta = cosf(0.5f * lt->theta);
                    if (rho <= cphi) continue;
                    if (rho < ctheta && ctheta > cphi) {
                        float fall = lt->falloff > 0.0f ? lt->falloff : 1.0f;
                        att *= powf((rho - cphi) / (ctheta - cphi), fall);
                    }
                }
            }
        }
        float ndotl = wn[0] * lx + wn[1] * ly + wn[2] * lz;
        if (ndotl < 0.0f) ndotl = 0.0f;
        if (rig->shading_mode == DC_SHADING_TOON) {
            float u = fminf(1.0f, fmaxf(0.0f, ndotl * att));
            float ramp = u < 0.2f ? 0.35f : (u < 0.55f ? 0.72f : 1.0f);
            for (unsigned c = 0; c < 3; ++c)
                diff[c] += m_amb[c] * lt->ambient[c] + ramp * m_diff[c] * lt->diffuse[c];
        } else {
            for (unsigned c = 0; c < 3; ++c)
                diff[c] += att * (m_amb[c] * lt->ambient[c] + ndotl * m_diff[c] * lt->diffuse[c]);
        }
        if (rig->enable_specular && m_power > 0.0f && ndotl > 0.0f) {
            float hx = lx + vx, hy = ly + vy, hz = lz + vz;
            float hl = sqrtf(hx * hx + hy * hy + hz * hz);
            if (isfinite(hl) && hl > 1e-8f) {
                hx /= hl; hy /= hl; hz /= hl;
                float ndoth = wn[0] * hx + wn[1] * hy + wn[2] * hz;
                if (ndoth > 0.0f) {
                    float sp = att * powf(ndoth, fminf(512.0f, m_power));
                    if (isfinite(sp)) {
                        for (unsigned c = 0; c < 3; ++c)
                            spec[c] += sp * m_spec[c] * lt->specular[c];
                    }
                }
            }
        }
    }

    for (unsigned c = 0; c < 3; ++c) {
        out_rgba[c] = fminf(1.0f, fmaxf(0.0f, isfinite(diff[c]) ? diff[c] : 0.0f));
        out_spec[c] = fminf(1.0f, fmaxf(0.0f, isfinite(spec[c]) ? spec[c] : 0.0f));
    }
    out_rgba[3] = m_alpha;

    out_sheen_uv[0] = 0.5;
    out_sheen_uv[1] = 0.5;
    if (rig->sheen_tci == DC_SHEEN_TCI_CAMERASPACENORMAL ||
        rig->sheen_tci == DC_SHEEN_TCI_CAMERASPACEREFLECTION) {
        const float *vm = rig->view_matrix.values;
        float nvx = wn[0] * vm[0] + wn[1] * vm[4] + wn[2] * vm[8];
        float nvy = wn[0] * vm[1] + wn[1] * vm[5] + wn[2] * vm[9];
        float nvz = wn[0] * vm[2] + wn[1] * vm[6] + wn[2] * vm[10];
        float nvl = sqrtf(nvx * nvx + nvy * nvy + nvz * nvz);
        if (isfinite(nvl) && nvl > 1e-8f) { nvx /= nvl; nvy /= nvl; nvz /= nvl; }
        if (rig->sheen_tci == DC_SHEEN_TCI_CAMERASPACENORMAL) {
            out_sheen_uv[0] = fminf(1.0f, fmaxf(0.0f, 0.5f + 0.5f * nvx));
            out_sheen_uv[1] = fminf(1.0f, fmaxf(0.0f, 0.5f - 0.5f * nvy));
        } else {
            float pvx = wp[0] * vm[0] + wp[1] * vm[4] + wp[2] * vm[8] + vm[12];
            float pvy = wp[0] * vm[1] + wp[1] * vm[5] + wp[2] * vm[9] + vm[13];
            float pvz = wp[0] * vm[2] + wp[1] * vm[6] + wp[2] * vm[10] + vm[14];
            float pvl = sqrtf(pvx * pvx + pvy * pvy + pvz * pvz);
            if (isfinite(pvl) && pvl > 1e-8f) {
                float ivx = pvx / pvl, ivy = pvy / pvl, ivz = pvz / pvl;
                float d2 = 2.0f * (ivx * nvx + ivy * nvy + ivz * nvz);
                float rvx = ivx - d2 * nvx;
                float rvy = ivy - d2 * nvy;
                out_sheen_uv[0] = fminf(1.0f, fmaxf(0.0f, 0.5f + 0.5f * rvx));
                out_sheen_uv[1] = fminf(1.0f, fmaxf(0.0f, 0.5f - 0.5f * rvy));
            }
        }
    }
}

dc_status dc_mesh_clip_project_lit(const dc_mesh_vertex *vertices, size_t vertex_count,
        const uint16_t *indices, size_t index_count, const dc_matrix *world_transform,
        const dc_matrix *mvp, const dc_viewport *viewport, const dc_material_value *material,
        const dc_light_rig *rig, dc_sprite_vertex *out, dc_sprite_vertex *spec_out,
        dc_sprite_vertex *sheen_out, size_t capacity, size_t *written, uint32_t *out_has_specular) {
    if (!vertices || !indices || !mvp || !viewport || !material || !rig || !written)
        return DC_ARGUMENT;
    if ((!out && capacity) || ((spec_out || sheen_out) && !out)) return DC_ARGUMENT;
    if (!vertex_count || vertex_count > 1048576 || !index_count || index_count > 1048576 ||
        index_count % 3 || capacity > 1048576 || rig->count > DC_LIGHT_RIG_MAX)
        return DC_RANGE;
    size_t bytes = capacity * sizeof(*out);
    if ((out && spec_out && overlaps(out, bytes, spec_out, bytes)) ||
        (out && sheen_out && overlaps(out, bytes, sheen_out, bytes)) ||
        (spec_out && sheen_out && overlaps(spec_out, bytes, sheen_out, bytes)))
        return DC_ARGUMENT;
    if (out_has_specular && overlaps(written, sizeof(*written), out_has_specular, sizeof(*out_has_specular)))
        return DC_ARGUMENT;
    const void *inputs[] = {vertices, indices, mvp, viewport, material, rig, world_transform};
    size_t lengths[] = {
        vertex_count * sizeof(*vertices), index_count * sizeof(*indices), sizeof(*mvp),
        sizeof(*viewport), sizeof(*material), sizeof(*rig), world_transform ? sizeof(*world_transform) : 0
    };
    dc_sprite_vertex *outs[3] = {out, spec_out, sheen_out};
    for (unsigned o = 0; o < 3; ++o) {
        if (!outs[o]) continue;
        if (overlaps(outs[o], bytes, written, sizeof(*written)) ||
            (out_has_specular && overlaps(outs[o], bytes, out_has_specular, sizeof(*out_has_specular))))
            return DC_ARGUMENT;
        for (unsigned i = 0; i < 7; ++i)
            if (lengths[i] && overlaps(inputs[i], lengths[i], outs[o], bytes))
                return DC_ARGUMENT;
    }
    for (unsigned i = 0; i < 7; ++i) {
        if (!lengths[i]) continue;
        if (overlaps(inputs[i], lengths[i], written, sizeof(*written)) ||
            (out_has_specular && overlaps(inputs[i], lengths[i], out_has_specular, sizeof(*out_has_specular))))
            return DC_ARGUMENT;
    }
    const float *view = &viewport->x;
    for (unsigned i = 0; i < 6; ++i) if (!isfinite(view[i])) return DC_RANGE;
    if (viewport->width <= 0 || viewport->height <= 0 || viewport->min_z < 0 || viewport->max_z > 1 ||
        viewport->min_z > viewport->max_z) return DC_RANGE;
    for (unsigned i = 0; i < 16; ++i) {
        if (!isfinite(mvp->values[i])) return DC_RANGE;
        if (world_transform && !isfinite(world_transform->values[i])) return DC_RANGE;
        if (!isfinite(rig->view_matrix.values[i])) return DC_RANGE;
    }
    for (unsigned i = 0; i < DC_MATERIAL_COMPONENTS; ++i)
        if (!isfinite(material->components[i])) return DC_RANGE;
    for (unsigned i = 0; i < 3; ++i)
        if (!isfinite(rig->global_ambient[i]) || !isfinite(rig->camera_eye[i])) return DC_RANGE;

    dc_sprite_vertex *res_base = (out && bytes) ? malloc(bytes) : NULL;
    dc_sprite_vertex *res_spec = (spec_out && bytes) ? malloc(bytes) : NULL;
    dc_sprite_vertex *res_sheen = (sheen_out && bytes) ? malloc(bytes) : NULL;
    if ((out && bytes && !res_base) || (spec_out && bytes && !res_spec) || (sheen_out && bytes && !res_sheen)) {
        free(res_base); free(res_spec); free(res_sheen);
        return DC_MEMORY;
    }

    float nmat[9];
    build_normal_matrix(world_transform, nmat);
    int need_shade = (out != NULL) || (out_has_specular != NULL);
    uint32_t any_spec = 0;
    dc_status status = DC_OK;
    size_t total = 0;

    for (size_t triangle = 0; triangle < index_count && status == DC_OK; triangle += 3) {
        lit_clip_vertex polygon[10];
        for (unsigned j = 0; j < 3; ++j) {
            uint16_t index = indices[triangle + j];
            if (index >= vertex_count) { status = DC_RANGE; break; }
            const dc_mesh_vertex *v = &vertices[index];
            if (!isfinite(v->uv[0]) || !isfinite(v->uv[1])) { status = DC_RANGE; break; }
            float p[4] = {v->position[0], v->position[1], v->position[2], 1.0f};
            for (unsigned k = 0; k < 4; ++k) if (!isfinite(p[k])) status = DC_RANGE;
            for (unsigned k = 0; k < 3; ++k) if (!isfinite(v->normal[k])) status = DC_RANGE;
            if (status != DC_OK) break;
            for (unsigned col = 0; col < 4; ++col) {
                float sum = 0.0f;
                for (unsigned k = 0; k < 4; ++k) {
                    volatile float product = p[k] * mvp->values[k * 4 + col];
                    sum += product;
                }
                if (!isfinite(sum)) { status = DC_RANGE; break; }
                polygon[j].p[col] = sum;
            }
            if (status != DC_OK) break;
            polygon[j].uv[0] = v->uv[0];
            polygon[j].uv[1] = v->uv[1];
            if (need_shade) {
                shade_vertex(v, world_transform, nmat, material, rig,
                             polygon[j].rgba, polygon[j].spec, polygon[j].sheen_uv);
            } else {
                polygon[j].sheen_uv[0] = 0.5; polygon[j].sheen_uv[1] = 0.5;
                polygon[j].rgba[0] = polygon[j].rgba[1] = polygon[j].rgba[2] = polygon[j].rgba[3] = 1.0;
                polygon[j].spec[0] = polygon[j].spec[1] = polygon[j].spec[2] = 0.0;
            }
        }
        if (status != DC_OK) break;
        size_t count = 3;
        status = clip_lit_triangle(polygon, &count);
        if (status != DC_OK || count < 3) continue;
        size_t added = (count - 2) * 3;
        if (added > 1048576 - total || (out && added > capacity - total)) { status = DC_RANGE; break; }
        dc_sprite_vertex proj_base[10], proj_spec[10], proj_sheen[10];
        for (size_t j = 0; j < count; ++j) {
            const lit_clip_vertex *v = &polygon[j];
            if (!(v->p[3] > 0.0)) { status = DC_RANGE; break; }
            double rw = 1.0 / v->p[3];
            float sx = (float)(viewport->x + (v->p[0] * rw + 1.0) * viewport->width * 0.5);
            float sy = (float)(viewport->y + (1.0 - v->p[1] * rw) * viewport->height * 0.5);
            float sz = (float)(viewport->min_z + v->p[2] * rw * (viewport->max_z - viewport->min_z));
            float rhw = (float)rw;
            float u0 = (float)v->uv[0], v0 = (float)v->uv[1];
            float su = (float)v->sheen_uv[0], sv = (float)v->sheen_uv[1];
            if (!isfinite(sx) || !isfinite(sy) || !isfinite(sz) || !isfinite(rhw) ||
                rhw <= 0.0f || !isfinite(u0) || !isfinite(v0) || !isfinite(su) || !isfinite(sv)) {
                status = DC_RANGE; break;
            }
            uint32_t diff_col = pack_d3d_color(v->rgba[0], v->rgba[1], v->rgba[2], v->rgba[3]);
            uint32_t spec_col = pack_d3d_color(v->spec[0], v->spec[1], v->spec[2], v->rgba[3]);
            uint32_t sheen_col = pack_d3d_color(1.0, 1.0, 1.0, v->rgba[3]);
            if ((spec_col & 0x00ffffffu) != 0u && (spec_col >> 24) != 0u) any_spec = 1u;
            proj_base[j] = (dc_sprite_vertex){.x = sx, .y = sy, .z = sz, .rhw = rhw,
                .diffuse = diff_col, .specular = 0xff000000u, .u = u0, .v = v0};
            proj_spec[j] = (dc_sprite_vertex){.x = sx, .y = sy, .z = sz, .rhw = rhw,
                .diffuse = spec_col, .specular = 0xff000000u, .u = 0.0f, .v = 0.0f};
            proj_sheen[j] = (dc_sprite_vertex){.x = sx, .y = sy, .z = sz, .rhw = rhw,
                .diffuse = sheen_col, .specular = 0xff000000u, .u = su, .v = sv};
        }
        if (status != DC_OK) break;
        if (out) {
            for (size_t j = 1; j + 1 < count; ++j) {
                size_t i0 = total, i1 = total + 1, i2 = total + 2;
                res_base[i0] = proj_base[0]; res_base[i1] = proj_base[j]; res_base[i2] = proj_base[j + 1];
                if (res_spec) {
                    res_spec[i0] = proj_spec[0]; res_spec[i1] = proj_spec[j]; res_spec[i2] = proj_spec[j + 1];
                }
                if (res_sheen) {
                    res_sheen[i0] = proj_sheen[0]; res_sheen[i1] = proj_sheen[j]; res_sheen[i2] = proj_sheen[j + 1];
                }
                total += 3;
            }
        } else {
            total += added;
        }
    }
    if (status == DC_OK) {
        if (total && out) {
            memcpy(out, res_base, total * sizeof(*out));
            if (spec_out) memcpy(spec_out, res_spec, total * sizeof(*spec_out));
            if (sheen_out) memcpy(sheen_out, res_sheen, total * sizeof(*sheen_out));
        }
        *written = total;
        if (out_has_specular) *out_has_specular = any_spec;
    }
    free(res_base);
    free(res_spec);
    free(res_sheen);
    return status;
}
