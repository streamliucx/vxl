
#include <vcl/vcl_iostream.h>
#include <vcl/vcl_list.h>

int main()
{
  typedef vcl_list<int> container;
  container m;
  
  m.push_back(1);
  m.push_back(2);

  for(container::iterator p = m.begin(); p != m.end(); ++p)
    cout << (*p) << endl;


  // fixme how do i do this on win32?  copy(m.begin(), m.end(), ostream_iterator<int>(cerr));

  return 0;
}
