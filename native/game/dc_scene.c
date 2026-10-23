#include "dc_scene.h"
#include <stdlib.h>
#include <string.h>

static int overlap(const void *a, size_t al, const void *b, size_t bl) {
    uintptr_t aa=(uintptr_t)a, bb=(uintptr_t)b;
    return al && bl && (aa<=bb ? bb-aa<al : aa-bb<bl);
}
dc_status dc_scene_update(const dc_scene_node *nodes, size_t count,
        const dc_matrix *world, dc_matrix *globals, size_t capacity) {
    if (!nodes || !world || !globals || !count || count>DC_SCENE_NODE_LIMIT) return DC_ARGUMENT;
    if (capacity<count) return DC_RANGE;
    size_t bytes=count*sizeof(*globals);
    if (overlap(nodes,count*sizeof(*nodes),globals,bytes) || overlap(world,sizeof(*world),globals,bytes)) return DC_ARGUMENT;
    dc_matrix *result=malloc(bytes);
    uint8_t *hidden=calloc(count,1);
    if (!result || !hidden) { free(result); free(hidden); return DC_MEMORY; }
    memcpy(result,globals,bytes);
    dc_status status=DC_OK;
    for (size_t i=0;i<count;++i) {
        const dc_scene_node *n=&nodes[i];
        if (n->parent!=DC_SCENE_NO_PARENT && n->parent>=i) { status=DC_FORMAT; break; }
        hidden[i]=n->hidden || (n->parent!=DC_SCENE_NO_PARENT && hidden[n->parent]);
        if (hidden[i]) continue;
        if (n->billboard || n->modifier>2) { status=DC_FORMAT; break; }
        const dc_matrix *parent=n->parent==DC_SCENE_NO_PARENT ? world : &result[n->parent];
        dc_matrix combined;
        status=dc_matrix_multiply(&n->local,parent,&combined);
        if (status!=DC_OK) break;
        if (n->modifier==1) {
            float translation[3]={combined.values[12],combined.values[13],combined.values[14]};
            combined.values[12]=combined.values[13]=combined.values[14]=0;
            status=dc_matrix_multiply(&combined,&n->extra,&result[i]);
            for (unsigned j=0;j<3;++j) result[i].values[12+j]=translation[j];
        } else if (n->modifier==2) status=dc_matrix_multiply(&n->extra,&combined,&result[i]);
        else result[i]=combined;
        if (status!=DC_OK) break;
    }
    if (status==DC_OK) memcpy(globals,result,bytes);
    free(result); free(hidden);
    return status;
}
