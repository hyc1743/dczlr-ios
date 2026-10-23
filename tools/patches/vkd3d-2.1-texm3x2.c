/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Copyright 2026 PortLab contributors.
 * Added to the LGPL vkd3d offline compiler; not part of the iOS runtime.
 * D3D ps_1_x TEXM3X2PAD/TEX use two consecutive texture coordinates as
 * rows of a 2x3 matrix, then sample the destination stage with the two dot
 * products. A PAD does not overwrite its visible destination texture register.
 * Reference: Microsoft's texm3x2tex pixel-shader instruction documentation.
 */
static enum vkd3d_result portlab_lower_texm3x2(struct vsir_program *program,
        struct vsir_program_iterator *it, unsigned int *pending_temp,
        unsigned int *pending_stage, struct vkd3d_shader_message_context *messages)
{
    struct vkd3d_shader_instruction *ins = vsir_program_iterator_current(it);
    const struct vkd3d_shader_location location = ins->location;
    const bool pad = ins->opcode == VSIR_OP_TEXM3x2PAD;
    struct vsir_dst_operand destination;
    struct vsir_src_operand source;
    const struct vsir_descriptor *descriptor;
    struct vsir_program_iterator before;
    unsigned int stage, temp;

    if (program->shader_version.type != VKD3D_SHADER_TYPE_PIXEL
            || program->shader_version.major != 1 || ins->dst_count != 1 || ins->src_count != 1
            || ins->dst[0].reg.type != VSIR_REGISTER_TEXTURE || ins->dst[0].reg.idx_count != 1)
        goto unsupported;
    destination = ins->dst[0];
    source = ins->src[0];
    stage = destination.reg.idx[0].offset;
    if (stage < 1 || stage > 3 || is_texture_projected(program, messages, stage))
        goto unsupported;

    if (pad)
    {
        if (*pending_temp != ~0u)
            goto unsupported;
        temp = program->temp_count++;
        *pending_temp = temp;
        *pending_stage = stage;
        ins = vsir_program_iterator_insert_before(it, &before, 1);
        if (!ins || !vsir_instruction_init_with_params(program, ins, &location, VSIR_OP_MOV, 1, 1))
            return VKD3D_ERROR_OUT_OF_MEMORY;
        vsir_dst_operand_init_temp_f32v4(&ins->dst[0], temp);
        vsir_src_operand_init_const_f32(&ins->src[0], 0.0f);
    }
    else
    {
        if (*pending_temp == ~0u || stage != *pending_stage + 1)
            goto unsupported;
        descriptor = vkd3d_shader_find_descriptor(&program->descriptors,
                VKD3D_SHADER_DESCRIPTOR_TYPE_SAMPLER, stage);
        if (!descriptor || descriptor->flags & VKD3D_SHADER_DESCRIPTOR_INFO_FLAG_SAMPLER_COMPARISON_MODE)
            goto unsupported;
        descriptor = vkd3d_shader_find_descriptor(&program->descriptors,
                VKD3D_SHADER_DESCRIPTOR_TYPE_SRV, stage);
        if (!descriptor || descriptor->resource_type != VKD3D_SHADER_RESOURCE_TEXTURE_2D)
            goto unsupported;
        temp = *pending_temp;
        if (!vsir_program_iterator_insert_after(it, 1))
            return VKD3D_ERROR_OUT_OF_MEMORY;
    }

    ins = vsir_program_iterator_current(it);
    if (!vsir_instruction_init_with_params(program, ins, &location, VSIR_OP_DP3, 1, 2))
        return VKD3D_ERROR_OUT_OF_MEMORY;
    vsir_dst_operand_init_temp_f32v4(&ins->dst[0], temp);
    ins->dst[0].write_mask = pad ? VKD3DSP_WRITEMASK_0 : VKD3DSP_WRITEMASK_1;
    vsir_src_operand_init(&ins->src[0], VSIR_REGISTER_TEXTURE, VSIR_DATA_F32, 1);
    ins->src[0].reg.idx[0].offset = stage;
    ins->src[0].reg.dimension = VSIR_DIMENSION_VEC4;
    ins->src[0].swizzle = VKD3D_SHADER_NO_SWIZZLE;
    ins->src[1] = source;

    if (!pad)
    {
        ins = vsir_program_iterator_next(it);
        if (!vsir_instruction_init_with_params(program, ins, &location, VSIR_OP_SAMPLE, 1, 3))
            return VKD3D_ERROR_OUT_OF_MEMORY;
        ins->dst[0] = destination;
        vsir_src_operand_init_temp_f32v4(&ins->src[0], temp);
        vsir_src_operand_init_resource(&ins->src[1], stage, stage);
        vsir_src_operand_init_sampler(&ins->src[2], stage, stage);
        *pending_temp = ~0u;
        *pending_stage = ~0u;
    }
    return VKD3D_OK;

unsupported:
    vkd3d_shader_error(messages, &location, VKD3D_SHADER_ERROR_VSIR_NOT_IMPLEMENTED,
            "Unsupported TEXM3X2 sequence, projection, or sampler dimension.");
    return VKD3D_ERROR_NOT_IMPLEMENTED;
}

/* CND selects SRC1 when SRC0 is strictly greater than 0.5, otherwise SRC2.
 * ps_1_1..1_3 broadcast source alpha; ps_1_4 selects per component.
 * Save the comparison before writing the destination, which can alias SRC0.
 */
static enum vkd3d_result portlab_lower_cnd(struct vsir_program *program,
        struct vsir_program_iterator *cnd)
{
    struct vkd3d_shader_instruction *ins = vsir_program_iterator_current(cnd);
    const struct vkd3d_shader_location location = ins->location;
    struct vsir_program_iterator before;
    struct vsir_src_operand sources[3];
    struct vsir_dst_operand destination;
    enum vsir_dimension dimension;
    unsigned int condition, flags;

    if (program->shader_version.type != VKD3D_SHADER_TYPE_PIXEL
            || program->shader_version.major != 1 || ins->dst_count != 1 || ins->src_count != 3)
        return VKD3D_ERROR_NOT_IMPLEMENTED;
    memcpy(sources, ins->src, sizeof(sources));
    destination = ins->dst[0];
    flags = ins->flags;
    dimension = sources[0].reg.dimension;
    if (program->shader_version.minor < 4)
        sources[0].swizzle = vsir_combine_swizzles(sources[0].swizzle, VKD3D_SHADER_SWIZZLE(W, W, W, W));

    ins = vsir_program_iterator_insert_before(cnd, &before, 1);
    if (!ins || !vsir_instruction_init_with_params(program, ins, &location, VSIR_OP_LTO, 1, 2))
        return VKD3D_ERROR_OUT_OF_MEMORY;
    condition = program->ssa_count++;
    vsir_dst_operand_init_ssa(&ins->dst[0], condition, VSIR_DATA_U32, dimension);
    vsir_src_operand_init_const_f32(&ins->src[0], 0.5f);
    ins->src[1] = sources[0];

    ins = vsir_program_iterator_current(cnd);
    if (!vsir_instruction_init_with_params(program, ins, &location, VSIR_OP_MOVC, 1, 3))
        return VKD3D_ERROR_OUT_OF_MEMORY;
    ins->flags = flags;
    ins->dst[0] = destination;
    vsir_src_operand_init_ssa(&ins->src[0], condition, VSIR_DATA_U32, dimension);
    ins->src[1] = sources[1];
    ins->src[2] = sources[2];
    return VKD3D_OK;
}
