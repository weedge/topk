#include <raft/sparse/detail/utils.h>
#include <stdint.h>
#include <stdlib.h>

#include <numeric>
#include <optional>
#include <raft/core/mdspan.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <raft/core/resources.hpp>
#include <raft/matrix/detail/select_warpsort.cuh>
#include <raft/matrix/select_k.cuh>
#include <raft/util/cudart_utils.hpp>
#include <rmm/device_uvector.hpp>
#include <vector>

void raft_matrix_selectk(int topk, int batch_size, int len,
                         const std::vector<float>& scores, const std::vector<int>& indeces,
                         std::vector<float>& s_scores, std::vector<int>& s_doc_ids) {
    raft::resources handle;
    auto stream = raft::resource::get_cuda_stream(handle);
    rmm::device_uvector<float> d_scores(scores.size(), stream);
    raft::update_device(d_scores.data(), scores.data(), scores.size(), stream);
    rmm::device_uvector<float> d_out_scores(batch_size * topk, stream);
    rmm::device_uvector<int> d_out_ids(batch_size * topk, stream);
    auto in_extent = raft::make_extents<int64_t>(batch_size, len);
    auto out_extent = raft::make_extents<int64_t>(batch_size, topk);
    auto in_span = raft::make_mdspan<const float, int64_t, raft::row_major, false, true>(d_scores.data(), in_extent);
    auto out_span = raft::make_mdspan<float, int64_t, raft::row_major, false, true>(d_out_scores.data(), out_extent);
    auto out_idx_span = raft::make_mdspan<int, int64_t, raft::row_major, false, true>(d_out_ids.data(), out_extent);

    // note: if in_idx_span is null use std::nullopt prevents automatic inference of the template parameters.
#ifdef NULL_OPTIONAL
    raft::matrix::select_k<float, int>(handle, in_span, std::nullopt, out_span, out_idx_span, false, true);
#else
    rmm::device_uvector<int> d_doc_ids(len, stream);
    if (indeces.empty()) {
        // like std:itoa on gpu device global memory
        raft::sparse::iota_fill(d_doc_ids.data(), batch_size, int(len), stream);
        // stream.synchronize();
    } else {
        raft::update_device(d_doc_ids.data(), indeces.data(), indeces.size(), stream);
    }
    auto in_idx_span = raft::make_mdspan<const int, int64_t, raft::row_major, false, true>(d_doc_ids.data(), in_extent);
    raft::matrix::select_k<float, int>(handle, in_span, in_idx_span, out_span, out_idx_span, false, true);
#endif

    raft::update_host(s_scores.data(), d_out_scores.data(), d_out_scores.size(), stream);
    raft::update_host(s_doc_ids.data(), d_out_ids.data(), d_out_ids.size(), stream);
    raft::interruptible::synchronize(stream);
}

int main(int argc, char* argv[]) {
    int topk = argc > 1 ? atoi(argv[1]) : 100;
    int batch_size = argc > 2 ? atoi(argv[2]) : 1;

    std::vector<float> scores = {0.928571, 0.9, 0.896552, 0.875, 0.875, 0.870968, 0.866667, 0.866667, 0.866667, 0.857143, 0.857143, 0.857143, 0.83871, 0.83871, 0.83871, 0.818182, 0.818182, 0.8125, 0.8125, 0.8125, 0.8125, 0.8125, 0.806452, 0.8, 0.794118, 0.794118, 0.787879, 0.787879, 0.787879, 0.78125, 0.771429, 0.771429, 0.771429, 0.764706, 0.764706, 0.764706, 0.764706, 0.757576, 0.742857, 0.742857, 0.72973, 0.72973, 0.722222, 0.722222, 0.722222, 0.722222, 0.722222, 0.71875, 0.702703, 0.702703, 0.702703, 0.702703, 0.702703, 0.702703, 0.692308, 0.685714, 0.684211, 0.684211, 0.676471, 0.666667, 0.658537, 0.634146, 0.628571, 0.611111, 0.606061, 0.604651, 0.571429, 0.568182, 0.565217, 0.522727, 0.490566, 0.485714, 0.482759, 0.466667, 0.466667, 0.464286, 0.464286, 0.464286, 0.464286, 0.464286, 0.464286, 0.464286, 0.454545, 0.451613, 0.451613, 0.451613, 0.451613, 0.451613, 0.451613, 0.448276, 0.448276, 0.448276, 0.448276, 0.448276, 0.444444, 0.441176, 0.441176, 0.441176, 0.4375, 0.4375, 0.4375, 0.4375, 0.4375, 0.4375, 0.4375, 0.4375, 0.4375, 0.4375, 0.4375, 0.4375, 0.433333, 0.433333, 0.433333, 0.433333, 0.433333, 0.433333, 0.433333, 0.433333, 0.433333, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.428571, 0.424242, 0.424242, 0.424242, 0.424242, 0.424242, 0.424242, 0.424242, 0.424242, 0.424242, 0.419355, 0.419355, 0.419355, 0.419355, 0.419355, 0.419355, 0.419355, 0.419355, 0.419355, 0.419355, 0.419355, 0.419355, 0.419355, 0.419355, 0.416667, 0.416667, 0.416667, 0.416667, 0.416667, 0.416667, 0.416667, 0.416667, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.413793, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.411765, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.40625, 0.405405, 0.405405, 0.405405, 0.405405, 0.405405, 0.405405, 0.405405, 0.405405, 0.405405, 0.405405, 0.405405, 0.405405, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.394737, 0.394737, 0.394737, 0.394737, 0.394737, 0.394737, 0.394737, 0.394737, 0.394737, 0.394737, 0.394737, 0.394737, 0.394737, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.393939, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.392857, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.388889, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.387097, 0.384615, 0.384615, 0.384615, 0.384615, 0.384615, 0.384615, 0.384615, 0.384615, 0.384615, 0.384615, 0.384615, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.382353, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.37931, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.378378, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429, 0.371429};
    size_t n_docs = scores.size();
    std::cout << "size:" << n_docs << " scores:" << std::endl;
    for (auto& s : scores) {
        // s *= -1;
        std::cout << s << ",";
    }
    std::cout << std::endl;

    // std::vector<int> indeces = {1064412,1212301,1165199,1324553,1337544,1279350,1221518,1244284,1244680,972283,1009627,1094325,1252175,1260777,1268224,1384210,1393825,1310814,1315547,1317017,1329501,1341171,1292801,1477389,1427999,1443623,1351931,1352887,1363146,1307186,1480921,1490375,1499799,1418128,1435011,1439307,1440123,1366052,1485951,1486511,1565048,1566093,1500616,1511639,1512826,1538358,1547424,1318251,1554073,1571537,1576178,1588176,1596407,1597752,1690975,1484789,1613338,1622281,1435168,1661370,1772693,1774156,1467924,1527674,1380085,1876256,574048,1951930,2078346,1932445,2416096,1450838,1182901,1216202,1237692,1060174,1086354,1091797,1100362,1123673,1133630,1149061,1348497,1255132,1255449,1260932,1264037,1275180,1288477,1150172,1153735,1184612,1184758,1189700,1535638,1403109,1403478,1408418,1299546,1303931,1305020,1307673,1308657,1310970,1313908,1328748,1331627,1335584,1337183,1337396,1205270,1207494,1210580,1215826,1224063,1229376,1233908,1239968,1244790,1052359,1056242,1058846,1082727,1084014,1086005,1088113,1090403,1094766,1095157,1098492,1120177,1123313,1125262,1132786,1137509,1139087,1139990,1143328,1145536,1449801,1450239,1462119,1463176,1467099,1473971,1354489,1356513,1357420,1372172,1373926,1389397,1392205,1395926,1397566,1248252,1249709,1253140,1263190,1266363,1269704,1283900,1284511,1286084,1286746,1287506,1290151,1290708,1296362,1510143,1520730,1528193,1538214,1541955,1546143,1546969,1547567,1149781,1150162,1157819,1158335,1160654,1161891,1163208,1163223,1164708,1167858,1173572,1175021,1178008,1178115,1181306,1185345,1186252,1187251,1188466,1188505,1189249,1190057,1190158,1190416,1191452,1195461,1195526,1196062,1404138,1406358,1410731,1416376,1420847,1422734,1424030,1424735,1428485,1431247,1431306,1431396,1436959,1439679,1442827,1443626,1444162,1444403,1299247,1300705,1302055,1302383,1307647,1308864,1309983,1310845,1311645,1311757,1314663,1318118,1321226,1322443,1323307,1324426,1325437,1327090,1327893,1329333,1329766,1329968,1330000,1333800,1335833,1336218,1336930,1338506,1339366,1339805,1340607,1342049,1342291,1342465,1344589,1346266,1347253,1347398,1347722,1555793,1556232,1566624,1570202,1571862,1572475,1574968,1577415,1592643,1593909,1598830,1599002,1198281,1199516,1199876,1200195,1202755,1204964,1205275,1206987,1207223,1210968,1211361,1211772,1212094,1212528,1212744,1216862,1217764,1218117,1218160,1218897,1219422,1221681,1223704,1226226,1226361,1227620,1227705,1227963,1228062,1228794,1228896,1231064,1233889,1234776,1234804,1235031,1236455,1237996,1239058,1240760,1243676,1244906,1245343,1245727,1247559,1449238,1458844,1458914,1460072,1462115,1462486,1465918,1468791,1469058,1469314,1473566,1476612,1479259,1480887,1481440,1482204,1482702,1483263,1485837,1486253,1489533,1494021,1497416,1607093,1608478,1609679,1617677,1625965,1626793,1627631,1629087,1630940,1631906,1633648,1635190,1646835,1348217,1348885,1349399,1349605,1351327,1351692,1351944,1352511,1352611,1353706,1355363,1355711,1356304,1357546,1357653,1358795,1359061,1359315,1359440,1359719,1361503,1365223,1365758,1366761,1367865,1368521,1368575,1370832,1370872,1373657,1374739,1375112,1376261,1376340,1377587,1380582,1381270,1381510,1381584,1382250,1382401,1382547,1382720,1382745,1383085,1383364,1383630,1383702,1383915,1388145,1388491,1388553,1388968,1391072,1391394,1392441,1393572,1394536,1394632,1395576,1395880,1396513,1396572,837823,860150,891234,927461,950256,954734,960400,965168,967692,970209,1005624,1007152,1013156,1023881,1029600,1037668,1044681,1049316,1049341,1049979,1051366,1052498,1054164,1054910,1058761,1059091,1066762,1068231,1070175,1073260,1073659,1078923,1079306,1082874,1084947,1086814,1091761,1094188,1094839,1097096,1100332,1100516,1103849,1105945,1106857,1107754,1108810,1109089,1112001,1112241,1112792,1113545,1115192,1115496,1116325,1116482,1117487,1118248,1118936,1120853,1124789,1125779,1126174,1127386,1131592,1132677,1133988,1137535,1140618,1142932,1147296,1147798,1499923,1500479,1503383,1503454,1504077,1504904,1505029,1508320,1511967,1512038,1514290,1519452,1522827,1523134,1527730,1529115,1529694,1532893,1535687,1535926,1536289,1536460,1537109,1537756,1539155,1539319,1539920,1540289,1540991,1542080,1542699,1543216,1543892,1546649,1546950,1547409,1550638,1249463,1250639,1252138,1253163,1254548,1254784,1255340,1255437,1255778,1256483,1256901,1257826,1258302,1258796,1259141,1260001,1260172,1261582,1263261,1263507,1263637,1264469,1264975,1265070,1266527,1266689,1266795,1267043,1267764,1268136,1268602,1268720,1269150,1269473,1269678,1270425,1270560,1272512,1273206,1274037,1274526,1275175,1275781,1278356,1280331,1281139,1281150,1281672,1282712,1284374,1285942,1286161,1287638,1287734,1287789,1288050,1288070,1288223,1290454,1291117,1291451,1292198,1292713,1293178,1293305,1293484,1294068,1295854,1666570,1669088,1669138,1669858,1676288,1683829,1692809,1697479,1697861,1705341,1706129,1399310,1399635,1399918,1400656,1401398,1402353,1403469,1404366,1404448,1404982,1405430,1406144,1406901,1406960,1407617,1407671,1408269,1408761,1408810,1409896,1411740,1412029,1412270,1413068,1413171,1414063,1414776,1414990,1416689,1417461,1419529,1419796,1420230,1420828,1422176,1422801,1425019,1425360,1425508,1425688,1426063,1430355,1432363,1434270,1434604,1436560,1437023,1437105,1437348,1437504,1437566,1437709,1439024,1439384,1441685,1442117,1442532,1443189,1443511,1443661,1444535,1447545,1447977,1448339,1149368,1152240,1152579,1152628,1153035,1154521,1156153,1156586,1156851,1157994,1158239,1159151,1159166,1161128,1162575,1164439,1168026,1168216,1168806,1170256,1170350,1171846,1172104,1172897,1173511,1174444,1175172,1175956,1176623,1179171,1180641,1181442,1181859,1183497,1184525,1184583,1186398,1188177,1188803,1191349,1192943,1193661,1194498,1196907,1551292,1553848,1554601,1556731,1556931,1558212,1558414,1559064,1559280,1560421,1560666,1560735,1562984,1563190,1563219,1564697,1565695,1566548,1567133,1568087,1569886,1570553,1571007,1571095,1571264,1572219,1572286,1573829,1576905,1577663,1578417,1578804,1579618,1580667,1580768,1581738,1584439,1585592,1585633,1586718,1586816,1587851,1593696,1594554,1595508,1595988,1596879,1597470,1598381,1598905,1599143,1599764,1600876,1603009,1297771,1298186,1298496,1298992,1299949,1300240,1300324,1300765,1301075,1302262,1302745,1302776,1303087,1304722,1305105,1305202,1305254,1305489,1305982,1305996,1306386,1306756,1307274,1307556,1307783,1307824,1308298,1308849,1309261,1309596,1310321,1310816,1311484,1312162,1312163,1313404,1314560,1314588,1314687,1315485,1315487,1315877,1316482,1316640,1316816,1316873,1317082,1318481,1318702,1320494,1320890,1321023,1322494,1322607,1322962,1323006,1323580,1323616,1324040,1324334,1324378,1324919,1325109,1326477,1326915,1327189,1327194,1327359,1327947,1328312,1329698,1331189,1331845,1331973,1332553,1332713,1333092,1333602,1333636,1334346,1334715,1335278,1335419,1335473,1338273,1338529,1338858,1338902,1339083,1339745,1340229,1340326,1340616,1340662,1340666,1341992,1342133,1342210,1342863,1343156,1343506,1343590,1343605,1343731,1343762,1344647,1344738,1345805,1345973,1346320,1347120,1347169,1347553,1347600,1347675,1347676,1710252,1711948,1717551,1723525,1723962,1734393,1736181,1738491,1741815,1742422,1748981,1751077,1752314,1755259,1759176,1759313,1759941,1449171,1449428,1449791,1450477,1450686,1451464,1451621,1452104,1452181,1452207,1452727,1453040,1453055,1454176,1455277,1455964,1456285,1457028,1458333,1458911,1459021,1459743,1460005,1460025,1460092,1460360,1460594,1461065,1461316,1461367,1461445,1461631,1462012,1462038,1462357,1464002,1464709,1465237,1466275,1466869,1466960,1467085,1467451,1467909,1468997,1469455,1469677,1470126,1470917,1471044,1471237,1471496,1471729,1472727,1472809,1472930,1474316,1474331,1474708,1475027,1475138,1475325,1475411,1475541,1475997,1475999,1476334,1477362,1477625,1477682,1477728,1478020,1478093,1478117,1478276,1478546,1478583,1478878,1479172,1479340,1479651,1480367,1480633,1482130,1482486,1483084,1483791,1484066,1484133,1484144,1484382,1484713,1485069,1485399,1486935,1487637,1488029,1488438,1488517,1488995};
    std::vector<int> indeces;
    std::cout << " indeces:" << std::endl;
    for (auto i : indeces) {
        std::cout << i << ",";
    }
    std::cout << std::endl;

    std::vector<float> s_scores(batch_size * topk);
    std::vector<int> s_doc_ids(batch_size * topk);

    raft_matrix_selectk(topk, batch_size, (n_docs + batch_size - 1) / batch_size, scores, indeces, s_scores, s_doc_ids);

    std::cout << "s_scores:" << std::endl;
    for (auto s : s_scores) {
        std::cout << s << ",";
    }
    std::cout << std::endl;
    std::cout << "s_doc_ids:" << std::endl;
    for (auto id : s_doc_ids) {
        std::cout << id << ",";
    }
    std::cout << std::endl;
}