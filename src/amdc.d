module amdc;

import std.math;
import std.stdio;
import std.container.array;
import std.typecons;
import std.conv;
import core.stdc.string;
import std.datetime.stopwatch;
import std.parallelism;
import std.range;

import core.stdc.stdlib : malloc;

import math;
import matrix;
import util;
import traits;
import graphics;
import render;
import hermite;

import umdc;


Array!uint whichEdgesAreSignedAll(uint config){//TODO make special table for this

    int* entry = &edgeTable[config][0];


    auto edges = Array!uint();
    edges.reserve(3);

    for(size_t i = 0; i < 16; ++i){
        auto k = entry[i];
        if(k >= 0){
            edges.insertBack(k);
        }else if(k == -1){
            continue;
        }else{
            return edges;
        }
    }

    return edges;
}


void constructQEF(const ref Array!(Plane!float) planes, Vector3!float centroid, out QEF!float qef){
    auto n = planes.length;
    auto Ab = Array!float();
    Ab.reserve(n * 4);
    Ab.length = n * 4;

    import lapacke;

    for(size_t i = 0; i < n; ++i){
        Ab[4*i]   = planes[i].normal.x;
        Ab[4*i+1] = planes[i].normal.y;
        Ab[4*i+2] = planes[i].normal.z;

        Ab[4*i+3] = planes[i].normal.dot(planes[i].point - centroid);
    }

    

    float[4] tau;


    LAPACKE_sgeqrf(LAPACK_ROW_MAJOR, cast(int)n, 4, &Ab[0], 4, tau.ptr);

    auto A = zero!(float,3,3)();
    for(size_t i = 0; i < 3; ++i){
        for(size_t j = i; j < 3; ++j){
            A[i,j] = Ab[4*i + j];
        }
    }

    auto b = vec3!float(Ab[3], Ab[7], Ab[11]);

    qef.a11 = Ab[0];
    qef.a12 = Ab[1];
    qef.a13 = Ab[2];
    qef.a22 = Ab[5];
    qef.a23 = Ab[6];
    qef.a33 = Ab[10];

    qef.b1 = Ab[3];
    qef.b2 = Ab[7];
    qef.b3 = Ab[11];
    
    if(n >= 4){ //TODO ?
        qef.r = Ab[15];
    }else{
        qef.r = 0;
    }

    qef.massPoint = centroid;

    


    auto U = zero!(float,3,3);
    auto VT = U;

    auto S = zero!(float,3,1);

    float[2] cache;

    LAPACKE_sgesvd(LAPACK_ROW_MAJOR, 'A', 'A', 3, 3, A.array.ptr, 3, S.array.ptr, U.array.ptr, 3, VT.array.ptr, 3, cache.ptr);


    size_t dim = 3;

    foreach(i;0..3){
        if(S[i].abs() < 0.1F){
            --dim;
            S[i] = 0.0F;
        }else{
            S[i] = 1.0F / S[i];
        }
    }

    auto Sm = diag3(S[0], S[1], S[2]);

    auto pinv = mult(mult(VT.transpose(), Sm), U.transpose());

    auto minimizer = mult(pinv, b);

    qef.n = cast(ubyte)dim;

    qef.minimizer = centroid + minimizer;

}

Node!(float)* sample(alias DenFn3)(ref DenFn3 f, Vector3!float offset, float a, size_t cellCount, size_t accuracy){

    ubyte maxDepth = cast(ubyte) log2(cellCount);
    

    auto size = cellCount;


    Array!ubyte signedGrid = Array!(ubyte)(); //TODO bit fields ?
    signedGrid.reserve((size + 1) * (size + 1) * (size + 1));
    signedGrid.length = (size + 1) * (size + 1) * (size + 1);
    

    Array!(Node!(float)*) grid = Array!(Node!(float)*)();
    grid.reserve(size * size * size);
    grid.length = size * size * size;


    pragma(inline,true)
    size_t indexDensity(size_t x, size_t y, size_t z){
        return z * (size + 1) * (size + 1) + y * (size + 1) + x;
    }


    pragma(inline,true)
    size_t indexCell(size_t x, size_t y, size_t z, size_t s = size){
        return z * s * s + y * s + x;
    }


    pragma(inline,true)
    Cube!float cube(size_t x, size_t y, size_t z){//cube bounds of a cell in the grid
        return Cube!float(offset + Vector3!float([(x + 0.5F)*a, (y + 0.5F) * a, (z + 0.5F) * a]), a / 2.0F);
    }

    pragma(inline, true)
    void sampleGridAt(size_t x, size_t y, size_t z){
        auto p = offset + vec3!float(x * a, y * a, z * a);
        immutable auto s = f(p);
        ubyte b;
        if(s < 0.0){
            b = 1;
        }
        signedGrid[indexDensity(x,y,z)] = b;
    }


    pragma(inline,true)
    void loadCell(size_t x, size_t y, size_t z){

        auto cellMin = offset + Vector3!float([x * a, y * a, z * a]);
        //immutable auto bounds = cube(x,y,z);

        uint config;


        if(signedGrid[indexDensity(x,y,z)]){
            config |= 1;
        }
        if(signedGrid[indexDensity(x+1,y,z)]){
            config |= 2;
        }
        if(signedGrid[indexDensity(x+1,y,z+1)]){
            config |= 4;
        }
        if(signedGrid[indexDensity(x,y,z+1)]){
            config |= 8;
        }

        if(signedGrid[indexDensity(x,y+1,z)]){
            config |= 16;
        }
        if(signedGrid[indexDensity(x+1,y+1,z)]){
            config |= 32;
        }
        if(signedGrid[indexDensity(x+1,y+1,z+1)]){
            config |= 64;
        }
        if(signedGrid[indexDensity(x,y+1,z+1)]){
            config |= 128;
        }

        if(config == 0){ //fully outside
            auto n = cast(HomogeneousNode!float*) malloc(HomogeneousNode!(float).sizeof);
            (*n).__node_type__ = NODE_TYPE_HOMOGENEOUS;
            (*n).isPositive = true;
            (*n).depth = maxDepth;
            grid[indexCell(x,y,z)] = cast(Node!float*)n;
        }else if(config == 255){ //fully inside
            auto n = cast(HomogeneousNode!float*) malloc(HomogeneousNode!(float).sizeof);
            (*n).__node_type__ = NODE_TYPE_HOMOGENEOUS;
            (*n).isPositive = false;
            (*n).depth = maxDepth;
            grid[indexCell(x,y,z)] = cast(Node!float*)n;
        }else{ //heterogeneous
            auto edges = whichEdgesAreSignedAll(config);

            auto n = cast(HeterogeneousNode!float*) malloc(HeterogeneousNode!(float).sizeof);
            (*n).__node_type__ = NODE_TYPE_HETEROGENEOUS;
            (*n).depth = maxDepth;


            auto planes = Array!(Plane!float)();
            Vector3!float centroid = zero3!float();

            foreach(curEntry; edges){
                import core.stdc.stdlib : malloc;
                HermiteData!(float)* data = cast(HermiteData!(float)*)malloc((HermiteData!float).sizeof); //TODO needs to be cleared

                auto corners = edgePairs[curEntry];
                auto edge = Line!(float,3)(cellMin + cornerPoints[corners.x] * a, cellMin + cornerPoints[corners.y] * a);
                auto intersection = sampleSurfaceIntersection!(DenFn3)(edge, cast(uint)accuracy.log2() + 1, f);
                auto normal = calculateNormal!(DenFn3)(intersection, a/1024.0F, f); //TODO division by 1024 is improper for very high sizes


                *data = HermiteData!float(intersection, normal);
                (*n).hermiteData[curEntry] = data;
                (*n).cornerSigns = cast(ubyte) config;

                centroid = centroid + intersection;
                planes.insertBack(Plane!float(intersection, normal));
            }

            centroid = centroid / planes.length;

            QEF!float qef;

            constructQEF(planes, centroid, qef);

            (*n).qef = qef;

            grid[indexCell(x,y,z)] = cast(Node!float*)n;
        }


    }


    pragma(inline,true)
    void simplify(size_t i, size_t j, size_t k, ref Array!(Node!(float)*) sparseGrid,
     ref Array!(Node!(float)*) denseGrid, size_t curSize, size_t curDepth){//depth is inverted

        auto n0 = denseGrid[indexCell(2*i, 2*j, 2*k, 2*curSize)];
        auto n1 = denseGrid[indexCell(2*i+1, 2*j, 2*k, 2*curSize)];
        auto n2 = denseGrid[indexCell(2*i+1, 2*j, 2*k+1, 2*curSize)];
        auto n3 = denseGrid[indexCell(2*i, 2*j, 2*k+1, 2*curSize)];

        auto n4 = denseGrid[indexCell(2*i, 2*j+1, 2*k, 2*curSize)];
        auto n5 = denseGrid[indexCell(2*i+1, 2*j+1, 2*k, 2*curSize)];
        auto n6 = denseGrid[indexCell(2*i+1, 2*j+1, 2*k+1, 2*curSize)];
        auto n7 = denseGrid[indexCell(2*i, 2*j+1, 2*k+1, 2*curSize)];

        Node!(float)*[8] nodes = [n0,n1,n2,n3,n4,n5,n6,n7];

        bool inited;
        bool isPositive;

        pragma(inline, true)
        void setInterior(){
            auto interior = cast(InteriorNode!(float)*) malloc(InteriorNode!(float).sizeof);
            (*interior).children = nodes;
            (*interior).depth = cast(ubyte) curDepth;
            (*interior).__node_type__ = NODE_TYPE_INTERIOR;

            sparseGrid[indexCell(i,j,k, curSize)] = cast(Node!(float)*)interior;
        }
        
        foreach(node; nodes){
            auto cur = (*node).__node_type__;
            if(cur == NODE_TYPE_HETEROGENEOUS || cur == NODE_TYPE_INTERIOR){
                setInterior();
                return;
            }else{ //homogeneous
                if(!inited){
                    inited = true;
                    isPositive = (*(cast(HomogeneousNode!(float)*) node)).isPositive;
                }else{
                    if((*(cast(HomogeneousNode!(float)*) node)).isPositive != isPositive){
                        setInterior();
                        return;
                    }
                }
            }  
        }

        //all cells are fully in or out
        auto homo = cast(HomogeneousNode!(float)*) malloc(HomogeneousNode!(float).sizeof);
        (*homo).isPositive = isPositive; 
        (*homo).depth = cast(ubyte) curDepth;
        (*homo).__node_type__ = NODE_TYPE_HOMOGENEOUS;

        sparseGrid[indexCell(i,j,k, curSize)] = cast(Node!(float)*)homo;
    }


    foreach(i; parallel(iota(0, (size+1) * (size+1) * (size+1) ))){
        auto z = i / (size+1) / (size+1);
        auto y = i / (size+1) % (size+1);
        auto x = i % (size+1);

        sampleGridAt(x,y,z);
    }

    foreach(i; parallel(iota(0, size * size * size ))){
        auto z = i / size / size;
        auto y = i / size % size;
        auto x = i % size;

        loadCell(x,y,z);
    }

    auto curSize = size;
    
    auto curDepth = maxDepth;

    while(curSize != 1){
        curSize /= 2;
        curDepth -= 1;

        Array!(Node!(float)*) sparseGrid = Array!(Node!(float)*)();
        sparseGrid.reserve(curSize * curSize * curSize);
        sparseGrid.length = (curSize * curSize * curSize);

        foreach(i; parallel(iota(0, curSize * curSize * curSize ))){
            auto z = i / curSize / curSize;
            auto y = i / curSize % curSize;
            auto x = i % curSize;

            simplify(x,y,z, sparseGrid, grid, curSize, curDepth);

            
        }

        grid = sparseGrid;
    }

    Node!(float)* tree = grid[0]; //grid contains only one element here

    return tree;

}


Vector3!float solveQEF(ref QEF!float qef){

    auto A = mat3!float(
        qef.a11, qef.a12, qef.a13,
        qef.a12, qef.a22, qef.a23,
        qef.a13, qef.a23, qef.a33
    );

    auto b = vec3!float(qef.b1, qef.b2, qef.b3);

    auto U = zero!(float,3,3);
    auto VT = U;

    auto S = zero!(float,3,1);

    float[2] cache;

    import lapacke;
    auto res = LAPACKE_sgesvd(LAPACK_ROW_MAJOR, 'A', 'A', 3, 3, A.array.ptr, 3, S.array.ptr, U.array.ptr, 3, VT.array.ptr, 3, cache.ptr);


    foreach(i;0..3){
        if(S[i].abs() < 0.1F){
            S[i] = 0.0F;
        }else{
            S[i] = 1.0F / S[i];
        }
    }

    auto Sm = diag3(S[0], S[1], S[2]);

    auto pinv = mult(mult(VT.transpose(), Sm), U.transpose());

    auto minimizer = mult(pinv, b);


    return minimizer;

}

// void generateIndices(Node!(float)* node, Cube!float bounds, ref Array!(Vector3!float) vertexBuffer){
//     foreachHeterogeneousLeaf!((node, bounds) => {
//         auto minimizer = solveQEF((*node).qef);
//         vertexBuffer.insertBack(minimizer);
//         (*node).index = cast(uint) vertexBuffer.length - 1;
//     })(node, bounds);
// }


auto faceProcTable2 = [1, 0, 1, 0,
                       1, 0, 1, 0,
                       2, 2, 2, 2]; //face dir table
auto faceProcTable3 = [[3,2,6,7,  0,1,5,4], [1,2,6,5,  0,3,7,4], [7,6,5,4,  3,2,1,0]]; //faceProc ->4 faceProc's
auto faceProcTable4 = [[[6,7,4,5,  11,10,9,8], [3,7,4,0,  6,2,0,4], [2,3,0,1,  11,10,9,8], [2,6,5,1,  6,2,0,4]],//
                       [[5,6,7,4,  10,9,8,11], [6,2,3,7,  1,5,7,3], [1,2,3,0,  10,9,8,11], [5,1,0,4,  1,5,7,3]],
                       [[4,5,1,0,  5,7,3,1], [7,4,0,3,  4,6,2,0], [7,6,2,3,  5,7,3,1], [6,5,1,2,  4,6,2,0]]]; //faceProc ->4 edgeProc's

auto edgeProcTable = [[0,1,5,4, 5,7,3,1],
                      [5,6,2,1, 2,0,4,6], 
                      [6,7,3,2, 3,1,5,7], 
                      [3,0,4,7, 4,6,2,0], 
                      [3,2,1,0, 9,8,11,10], 
                      [7,6,5,4, 9,8,11,10]]; //cellProc ->6 edgeProc


auto edgeProcTable2 = [
                                    [0u,1u],
                                    [1u,2u],
                                    [3u,2u],
                                    [0u,3u],

                                    [4u,5u],
                                    [5u,6u],
                                    [7u,6u],
                                    [4u,7u],

                                    [0u,4u],
                                    [1u,5u],
                                    [2u,6u],
                                    [3u,7u],
];

void faceProc(RenderVertFragDef renderer, Node!(float)* a, Node!(float)* b, uint dir){


    if(nodeType(a) == NODE_TYPE_HOMOGENEOUS || nodeType(b) == NODE_TYPE_HOMOGENEOUS){
        return;
    }


    auto n = &faceProcTable4[dir];
    auto t = &faceProcTable3[dir];
    
    switch(nodeType(a)){
        case NODE_TYPE_INTERIOR:

            auto aint = cast( InteriorNode!(float)* ) a;
            

            
            switch(nodeType(b)){
                case NODE_TYPE_INTERIOR: //both nodes are internal
                    auto bint = cast( InteriorNode!(float)* ) b;
             

                    foreach(i;0..4){
                        faceProc(renderer, aint.children[(*t)[i]], bint.children[(*t)[i+4]], dir); //ok
                        
                        edgeProc(renderer, aint.children[(*n)[i][0]], aint.children[(*n)[i][1]], bint.children[(*n)[i][2]], bint.children[(*n)[i][3]], (*n)[i][4], (*n)[i][5], (*n)[i][6], (*n)[i][7]); //ok
                    }

                    break;

                default:
                    foreach(i;0..4){
                        faceProc(renderer, aint.children[(*t)[i]], b, dir); //ok

                        edgeProc(renderer, aint.children[(*n)[i][0]], aint.children[(*n)[i][1]], b, b, (*n)[i][4], (*n)[i][5], (*n)[i][6], (*n)[i][7]); //ok
                    }

                    break;
            }

            break;
            
        default:

            switch(nodeType(b)){
                case NODE_TYPE_INTERIOR:
                    auto bint = cast( InteriorNode!(float)* ) b;


                    foreach(i;0..4){
                        faceProc(renderer, a, bint.children[(*t)[i+4]], dir); //ok

                        edgeProc(renderer, a, a, bint.children[(*n)[i][2]], bint.children[(*n)[i][3]], (*n)[i][4], (*n)[i][5], (*n)[i][6], (*n)[i][7]); //ok
                    }

                    break;

                default:
                    break;
            }

            break;
    }
}

static int CALLS = 0;
void edgeProc(RenderVertFragDef renderer, Node!(float)* a, Node!(float)* b, Node!(float)* c, Node!(float)* d, size_t ai, size_t bi, size_t ci, size_t di){
    auto types = [nodeType(a), nodeType(b), nodeType(c), nodeType(d)];
    auto nodes = [a,b,c,d];
    auto configs = [ai,bi,ci,di];
    

    if(types[0] != NODE_TYPE_INTERIOR && types[1] != NODE_TYPE_INTERIOR && types[2] != NODE_TYPE_INTERIOR && types[3] != NODE_TYPE_INTERIOR){ //none of the nodes are interior
        //all nodes are heterogeneous
        //TODO make the condition computation faster ^^^ only one check is needed if NODE_TYPE_X are set correctly

        if(types[0] == NODE_TYPE_HOMOGENEOUS || types[1] == NODE_TYPE_HOMOGENEOUS || types[2] == NODE_TYPE_HOMOGENEOUS || types[3] == NODE_TYPE_HOMOGENEOUS){
            return;
        }
       
        

        CALLS += 1;

        Vector3!float[4] pos;
        Vector3!float color = vecS!([1.0F,1.0F,1.0F]);
        Vector3!float normal;

        size_t index = -1;
        size_t minDepth = size_t.max;
        bool flip2;

        int[4] sc;
        

        foreach(i;0..4){
            auto node = cast(HeterogeneousNode!float*) nodes[i];
            auto p = edgeProcTable2[configs[i]]; //TODO
            auto p1 = (node.cornerSigns >> p[0]) & 1;
            auto p2 = (node.cornerSigns >> p[1]) & 1;

            if(node.depth < minDepth){
                index = i;
                minDepth = node.depth;

                if(p1 == 0){
                    flip2 = true;
                }
            }

            if(p1 != p2){
                sc[i] = 1;
            }else{
                sc[i] = 0;
            }

            pos[i] = node.qef.minimizer;


        }

        if(sc[index] == 0) return;

        auto node = (* cast(HeterogeneousNode!float*) nodes[index]);

        normal = node.hermiteData[configs[index]].normal;

        auto nodesh = [asHetero!float(a),asHetero!float(b),asHetero!float(c),asHetero!float(d)];

        if(nodes[0] == nodes[1]){//same nodes => triangle
            addTriangleColorNormal(renderer, Triangle!(float,3)( (*nodesh[0]).qef.minimizer, (*nodesh[3]).qef.minimizer, (*nodesh[2]).qef.minimizer ), color, normal);
        }else if(nodes[1] == nodes[3]){
            addTriangleColorNormal(renderer, Triangle!(float,3)( (*nodesh[0]).qef.minimizer, (*nodesh[1]).qef.minimizer, (*nodesh[2]).qef.minimizer ), color, normal);
        }else if(nodes[3] == nodes[2]){
            addTriangleColorNormal(renderer, Triangle!(float,3)( (*nodesh[0]).qef.minimizer, (*nodesh[1]).qef.minimizer, (*nodesh[3]).qef.minimizer ), color, normal);
        }else if(nodes[2] == nodes[0]){
            addTriangleColorNormal(renderer, Triangle!(float,3)( (*nodesh[1]).qef.minimizer, (*nodesh[3]).qef.minimizer, (*nodesh[2]).qef.minimizer ), color, normal);
        }else{

            if(!flip2){
                addTriangleColorNormal(renderer, Triangle!(float,3)( (*nodesh[0]).qef.minimizer, (*nodesh[1]).qef.minimizer, (*nodesh[2]).qef.minimizer ), color, normal);
                addTriangleColorNormal(renderer, Triangle!(float,3)( (*nodesh[0]).qef.minimizer, (*nodesh[2]).qef.minimizer, (*nodesh[3]).qef.minimizer ), color, normal);
            }else{
                addTriangleColorNormal(renderer, Triangle!(float,3)( (*nodesh[0]).qef.minimizer, (*nodesh[2]).qef.minimizer, (*nodesh[1]).qef.minimizer ), color, normal);
                addTriangleColorNormal(renderer, Triangle!(float,3)( (*nodesh[0]).qef.minimizer, (*nodesh[3]).qef.minimizer, (*nodesh[2]).qef.minimizer ), color, normal);
            }

        

            
        }

        

        

    }else{//subdivide
        Node!(float)*[4] sub1;
        Node!(float)*[4] sub2;
        foreach(i;0..4){
            if(types[i] != NODE_TYPE_INTERIOR){
                sub1[i] = nodes[i];
                sub2[i] = nodes[i];
            }else{
                auto interior = cast( InteriorNode!(float)* ) nodes[i];
                auto p = edgeProcTable2[configs[i]];
                sub1[i] = interior.children[p[0]];
                sub2[i] = interior.children[p[1]];
            }
        }

        edgeProc(renderer, sub1[0], sub1[1], sub1[2], sub1[3], ai, bi, ci, di);
        edgeProc(renderer, sub2[0], sub2[1], sub2[2], sub2[3], ai, bi, ci, di);
    }
}

void cellProc(RenderVertFragDef renderer, Node!(float)* node){ //ok
    switch(nodeType(node)){
        case NODE_TYPE_INTERIOR:
            auto interior = cast( InteriorNode!(float)* ) node;
            auto ch = (*interior).children;

            foreach(i;0..8){
                auto c = ch[i];
                cellProc(renderer, c); //ok
            }

            foreach(i;0..12){
                auto pair = edgeProcTable2[i];
                auto dir = faceProcTable2[i];
                faceProc(renderer, ch[pair[0]], ch[pair[1]], dir); //ok
            }

            foreach(i;0..6){
                auto tuple8 = &edgeProcTable[i];
                edgeProc(renderer, ch[(*tuple8)[0]], ch[(*tuple8)[1]], ch[(*tuple8)[2]], ch[(*tuple8)[3]],
                                   (*tuple8)[4], (*tuple8)[5], (*tuple8)[6], (*tuple8)[7]);//ok
            }


            break;
            
        default: break;
    }
}

void foreachHeterogeneousLeaf(alias f)(Node!(float)* node, Cube!float bounds){
    final switch(nodeType(node)){
        case NODE_TYPE_INTERIOR:
            auto interior = cast( InteriorNode!(float)* ) node;
            auto ch = (*interior).children;

            foreach(i;0..8){
                auto c = ch[i];
                auto tr = cornerPointsOrigin[i] * bounds.extent / 2;
                auto newBounds = Cube!(float)(bounds.center + tr, bounds.extent/2);

                foreachHeterogeneousLeaf!(f)(c, newBounds);
            }
            break;

        case NODE_TYPE_HOMOGENEOUS:
            break;
        case NODE_TYPE_HETEROGENEOUS:
            f( cast(HeterogeneousNode!float*)  node, bounds);
            break;

    }
}


void foreachLeaf(alias f)(Node!(float)* node, Cube!float bounds){
    final switch(nodeType(node)){
        case NODE_TYPE_INTERIOR:
            auto interior = cast( InteriorNode!(float)* ) node;
            auto ch = (*interior).children;

            foreach(i;0..8){
                auto c = ch[i];
                auto tr = cornerPointsOrigin[i] * bounds.extent / 2;
                auto newBounds = Cube!(float)(bounds.center + tr, bounds.extent/2);

                foreachLeaf!(f)(c, newBounds);
            }
            break;

        case NODE_TYPE_HOMOGENEOUS:
            f(node, bounds);
            break;
        case NODE_TYPE_HETEROGENEOUS:
            f(node, bounds);
            break;

    }
}

